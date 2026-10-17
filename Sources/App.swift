import AppKit
import SwiftUI

@MainActor
final class BrewModel: ObservableObject {
    @Published var packages: [Package] = []
    @Published var log = ""
    @Published var busy: String?
    @Published var loadError: String?

    /// When set, every refresh writes the listed packages here so the UI state can be diffed against `brew list`.
    let dumpPath = ProcessInfo.processInfo.environment["BODEGA_DUMP"]

    func refresh() async {
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
        var args = [verb]
        if cask { args.append("--cask") }
        args.append(name)
        busy = "brew \(args.joined(separator: " "))…"
        log += "$ brew \(args.joined(separator: " "))\n"
        let r = await Brew.run(args)
        log += r.output + (r.status == 0 ? "✔ done\n\n" : "✘ exit \(r.status)\n\n")
        busy = nil
        await refresh()
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
                Text(status).font(.caption).foregroundStyle(.secondary)
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

            ScrollView {
                Text(model.log.isEmpty ? "brew output appears here" : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
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
