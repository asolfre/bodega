import AppKit
import SwiftUI

@MainActor
final class BrewModel: ObservableObject {
    @Published var packages: [Package] = []
    @Published var log = ""
    @Published var busy: String?
    @Published var loadError: String?
    @Published var running: Process?
    private var cancelled = false

    /// When set, every refresh writes the listed packages here so the UI state can be diffed against `brew list`.
    let dumpPath = ProcessInfo.processInfo.environment["BODEGA_DUMP"]

    func refresh() async {
        guard busy == nil else { return }
        busy = "Loading installed packages…"
        defer { busy = nil }
        do {
            packages = try await Brew.installed()
            loadError = nil
            if let dumpPath {
                let lines = packages.map {
                    "\($0.kind.rawValue)\t\($0.name)\t\($0.version)\t\($0.latest ?? "")\t\($0.active ?? "")"
                }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
            }
        } catch {
            loadError = "Could not read brew output: \(error.localizedDescription)"
        }
    }

    func perform(_ verb: String, _ name: String, cask: Bool) async {
        guard busy == nil else { return }
        var args = [verb]
        if cask { args.append("--cask") }
        args.append(name)
        let command = "brew \(args.joined(separator: " "))"
        busy = "\(command)…"
        cancelled = false
        show("$ \(command)")
        Self.writeLog("$ \(command)")
        let r = await Brew.run(args, onStart: { self.running = $0 }, onLine: { line in
            self.show(line)
            Self.writeLog("  \(line)")
        })
        running = nil
        let end = cancelled ? "cancelled (exit \(r.status))" : "exit \(r.status)"
        show((r.status == 0 && !cancelled ? "✔ " : "✘ ") + end + "\n")
        Self.writeLog(end)
        busy = nil
        await refresh()
    }

    /// Same as Ctrl-C in a terminal: brew gets SIGINT and cleans up its own half-done work.
    func cancel() {
        guard let running, running.isRunning else { return }
        cancelled = true
        running.interrupt()
    }

    private func show(_ line: String) {
        log += line + "\n"
        // ponytail: keeps only the newest ~200 KB on screen; Bodega.log has everything.
        if log.utf8.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Bodega.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Every line gets its own time, so the file shows output arriving while brew ran.
    private static func writeLog(_ text: String) {
        let line = Data("[\(stamp.string(from: Date()))] \(text)\n".utf8)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: logURL)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: BrewModel
    @State private var filter = ""
    @State private var installName = ""
    @State private var installCask = false
    @State private var pendingUninstall: Package?

    var shown: [Package] {
        filter.isEmpty ? model.packages : model.packages.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Package to install", text: $installName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit(install)
                    Toggle("Cask", isOn: $installCask)
                    Button("Install", action: install)
                        .disabled(installName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil)
                    Spacer()
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.busy != nil)
                }
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if model.running != nil {
                        Button("Cancel") { model.cancel() }.controlSize(.small)
                    }
                }
                Table(shown) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Type") { Text($0.kind.rawValue) }.width(70)
                    TableColumn("Installed") { p in
                        let v = p.displayVersions
                        (Text(v.first ?? "")
                         + Text(v.count > 1 ? " " + v.dropFirst().joined(separator: " ") : "").foregroundColor(.secondary))
                    }.width(120)
                    TableColumn("Latest") { p in
                        Text(p.latest ?? "—").foregroundStyle(p.latest == nil ? .secondary : Color.orange)
                    }.width(120)
                    TableColumn("Actions") { p in
                        HStack {
                            Button("Update") { Task { await model.perform("upgrade", p.name, cask: p.kind == .cask) } }
                                .disabled(p.latest == nil || model.busy != nil)
                            Button("Uninstall") { pendingUninstall = p }
                                .disabled(model.busy != nil)
                        }
                    }.width(170)
                }
            }
            .padding()
            .frame(minHeight: 300)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? "brew output appears here" : model.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(minHeight: 100)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await model.refresh() }
        .confirmationDialog("Uninstall \(pendingUninstall?.name ?? "")?",
                            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } })) {
            Button("Uninstall", role: .destructive) {
                if let p = pendingUninstall { Task { await model.perform("uninstall", p.name, cask: p.kind == .cask) } }
            }
        }
    }

    var status: String {
        if let b = model.busy { return b }
        if let e = model.loadError { return e }
        let f = model.packages.filter { $0.kind == .formula }.count
        let outdated = model.packages.filter { $0.latest != nil }.count
        return "\(f) formulae, \(model.packages.count - f) casks, \(outdated) outdated"
    }

    func install() {
        let name = installName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, model.busy == nil else { return }
        installName = ""
        Task { await model.perform("install", name, cask: installCask) }
    }
}

@main
struct BodegaApp: App {
    @StateObject private var model = BrewModel()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Bodega") { ContentView().environmentObject(model) }
    }
}
