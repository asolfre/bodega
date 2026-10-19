import AppKit
import SwiftUI

@MainActor
final class BrewModel: ObservableObject {
    @Published var packages: [Package] = []
    /// Separate object: only the log pane watches it, so a new line does not redraw the table.
    let output = LogStore()
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
        output.text += line + "\n"
        // ponytail: keeps only the newest ~200 KB on screen; Bodega.log has everything.
        if output.text.utf8.count > 200_000 { output.text = String(output.text.suffix(150_000)) }
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
    @State private var query = ""
    @State private var searching = false
    @State private var results: [SearchResult]?
    @State private var searchError: String?
    @State private var pendingUninstall: Package?

    var shown: [Package] {
        filter.isEmpty ? model.packages : model.packages.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Search packages to install", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(search)
                        .accessibilityIdentifier("search-field")
                    Button("Search", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                        .accessibilityIdentifier("search-button")
                    Spacer()
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .accessibilityIdentifier("filter-field")
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("refresh-button")
                }
                HStack {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("status")
                    if model.running != nil {
                        Button("Cancel") { model.cancel() }.controlSize(.small)
                            .accessibilityIdentifier("cancel-button")
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
                                .accessibilityIdentifier("update-\(p.name)")
                            Button("Uninstall") { pendingUninstall = p }
                                .disabled(model.busy != nil)
                                .accessibilityIdentifier("uninstall-\(p.name)")
                        }
                    }.width(170)
                }
            }
            .padding()
            .frame(minHeight: 300)

            LogView(store: model.output)
            .frame(minHeight: 100)
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await model.refresh() }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) {
            SearchSheet(query: query, results: results ?? [], error: searchError) { results = nil }
                .environmentObject(model)
        }
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

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        searching = true
        Task {
            do { results = try await Brew.search(q); searchError = nil } catch {
                results = []; searchError = error.localizedDescription
            }
            searching = false
        }
    }
}

struct SearchSheet: View {
    @EnvironmentObject var model: BrewModel
    let query: String
    let results: [SearchResult]
    let error: String?
    let close: () -> Void

    var installed: Set<String> { Set(model.packages.map { "\($0.kind.rawValue):\($0.name)" }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Results for “\(query)”").font(.headline)
            if let error { Text(error).foregroundStyle(.red) }
            if results.isEmpty {
                Text("No results").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityIdentifier("no-results")
            } else {
                List(results) { r in
                    HStack {
                        Text(r.name)
                        Spacer()
                        Text(r.kind.rawValue).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        if installed.contains("\(r.kind.rawValue):\(r.shortName)") {
                            Text("installed").foregroundStyle(.secondary).frame(width: 70)
                                .accessibilityIdentifier("installed-\(r.id)")
                        } else {
                            Button("Install") {
                                close()
                                Task { await model.perform("install", r.name, cask: r.kind == .cask) }
                            }
                            .disabled(model.busy != nil)
                            .frame(width: 70)
                            .accessibilityIdentifier("install-\(r.id)")
                        }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("close-results") }
        }
        .padding()
        .frame(width: 520)
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

final class LogStore: ObservableObject {
    @Published var text = ""
}

struct LogView: View {
    @ObservedObject var store: LogStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(store.text.isEmpty ? "brew output appears here" : store.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .accessibilityIdentifier("log")
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: store.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
