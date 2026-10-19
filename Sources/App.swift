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
    @Published var cleanupPreview: CleanupPreview?
    @Published var upgradePreview: UpgradePreview?
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
                        + "\t\($0.pinned ? 1 : 0)\t\($0.untrusted ? 1 : 0)"
                }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
            }
        } catch {
            loadError = "Could not read brew output: \(error.localizedDescription)"
        }
    }

    func perform(_ verb: String, _ name: String, cask: Bool) async {
        await perform(cask ? [verb, "--cask", name] : [verb, name])
    }

    func perform(_ args: [String]) async {
        guard busy == nil else { return }
        let command = "brew \(args.joined(separator: " "))"
        busy = "\(command)…"
        cancelled = false
        output.append("$ \(command)")
        Self.writeLog("$ \(command)")
        let r = await Brew.run(args, onStart: { self.running = $0 }, onLine: { line in
            self.output.append(line)
            Self.writeLog("  \(line)")
        })
        running = nil
        let end = cancelled ? "cancelled (exit \(r.status))" : "exit \(r.status)"
        output.append((r.status == 0 && !cancelled ? "✔ " : "✘ ") + end)
        output.append("")
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

    /// `brew cleanup -n` takes about a minute, so it holds the busy guard like any action.
    /// stdout only: the "Warning: Skipping …" lines come on stderr and could split a "Would remove" line.
    func previewCleanup() async {
        guard busy == nil else { return }
        busy = "Checking what brew cleanup would remove…"
        let out = (try? await Brew.stdout(["cleanup", "-n"]))?.1 ?? Data()
        busy = nil
        cleanupPreview = Brew.parseCleanup(String(decoding: out, as: UTF8.self))
    }

    /// Shows what the upgrade would really do before it runs. The dry run lists dependencies too
    /// (e.g. one you uninstalled), and the bottle check finds every formula that would compile.
    /// A single-package update with nothing else to it starts straight away.
    func previewUpgrade(_ package: Package? = nil) async {
        guard busy == nil else { return }
        var command = ["upgrade"]
        if let package { command += package.kind == .cask ? ["--cask", package.name] : [package.name] }
        busy = "Checking what brew \(command.joined(separator: " ")) would do…"
        let preview = await Brew.previewUpgrade(command)
        busy = nil
        if package != nil, preview.upgrades.count == 1, preview.dependencyUpgrades.isEmpty,
           preview.newDependencies.isEmpty, preview.sourceBuilds == [] {
            await perform(command)
        } else {
            upgradePreview = preview
        }
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Bodega.log")

    /// At launch: over 5 MB, the log becomes Bodega.log.1 (replacing the older one) and a new log starts.
    static func rotateLog(limit: Int = 5_000_000) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > limit else { return }
        let old = logURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logURL, to: old)
    }

    init() { Self.rotateLog() }
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
                    Button("Update all…") { Task { await model.previewUpgrade() } }
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("update-all-button")
                    Button("Clean up…") { Task { await model.previewCleanup() } }
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("cleanup-button")
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
                    TableColumn("Name") { p in
                        HStack(spacing: 4) {
                            Text(p.name)
                            if p.pinned {
                                Image(systemName: "pin.fill").foregroundStyle(.secondary)
                                    .accessibilityIdentifier("pinned-\(p.name)")
                            }
                            if p.untrusted {
                                Text("untrusted tap").font(.caption2).foregroundStyle(.orange)
                                    .accessibilityIdentifier("untrusted-\(p.name)")
                            }
                        }
                    }
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
                            Button("Update") { Task { await model.previewUpgrade(p) } }
                                .disabled(p.latest == nil || p.pinned || model.busy != nil)
                                .accessibilityIdentifier("update-\(p.name)")
                            Button("Uninstall") { pendingUninstall = p }
                                .disabled(model.busy != nil)
                                .accessibilityIdentifier("uninstall-\(p.name)")
                            if p.kind == .formula {
                                Button(p.pinned ? "Unpin" : "Pin") {
                                    Task { await model.perform(p.pinned ? "unpin" : "pin", p.name, cask: false) }
                                }
                                .disabled(model.busy != nil)
                                .accessibilityIdentifier("\(p.pinned ? "unpin" : "pin")-\(p.name)")
                            }
                        }
                    }.width(220)
                }
            }
            .padding()
            .frame(minHeight: 300)

            LogView(store: model.output)
            .frame(minHeight: 100)
        }
        .frame(minWidth: 860, minHeight: 520)
        .task { await model.refresh() }
        .sheet(isPresented: Binding(get: { results != nil }, set: { if !$0 { results = nil } })) {
            SearchSheet(query: query, results: results ?? [], error: searchError) { results = nil }
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.upgradePreview != nil }, set: { if !$0 { model.upgradePreview = nil } })) {
            UpgradeSheet(preview: model.upgradePreview ?? UpgradePreview()) { confirmed in
                let command = model.upgradePreview?.command ?? ["upgrade"]
                model.upgradePreview = nil
                if confirmed { Task { await model.perform(command) } }
            }
        }
        .alert(model.cleanupPreview?.count == 0 ? "Nothing to clean up" : "Clean up?",
               isPresented: Binding(get: { model.cleanupPreview != nil }, set: { if !$0 { model.cleanupPreview = nil } }),
               presenting: model.cleanupPreview) { p in
            if p.count > 0 {
                Button("Clean up", role: .destructive) { Task { await model.perform(["cleanup"]) } }
            }
            Button(p.count > 0 ? "Cancel" : "OK", role: .cancel) {}
        } message: { p in
            Text("brew cleanup would remove \(p.count) items. \(p.summary ?? "")\n\n"
                 + "Brew also does this by itself every 30 days during installs and updates.")
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

struct UpgradeSheet: View {
    let preview: UpgradePreview
    let done: (_ confirmed: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.upgrades.isEmpty ? "Nothing to update"
                 : preview.command.count > 1 ? "Update \(preview.command.last ?? "")?"
                 : "Update \(preview.upgrades.count) packages?")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Upgrades", preview.upgrades)
                    section("Dependencies that would also be upgraded", preview.dependencyUpgrades)
                    section("New dependencies that would be installed", preview.newDependencies)
                    if let builds = preview.sourceBuilds {
                        if !builds.isEmpty {
                            Text("Homebrew has no ready-made packages for this macOS version (Tier 3), so these "
                                 + "\(builds.count) formulae would compile from source. That can take hours; "
                                 + "Cancel in the main window stops it.")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            section("Would build from source", builds)
                        }
                    } else if !preview.upgrades.isEmpty {
                        Text("Could not check which of these would compile from source.")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("upgrade-cancel")
                if !preview.upgrades.isEmpty {
                    Button("Update") { done(true) }
                        .accessibilityIdentifier("upgrade-confirm")
                }
            }
        }
        .padding()
        .frame(width: 560)
    }

    @ViewBuilder
    private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) (\(lines.count))").bold()
                ForEach(lines, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
            }
        }
    }
}

/// New lines are published at most 10 times a second, and the pane only lays out visible lines:
/// one big Text was re-typeset on every line and fell minutes behind a long `brew cleanup`.
@MainActor
final class LogStore: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private var pending: [String] = []
    private var nextID = 0

    func append(_ text: String) {
        pending.append(text)
        guard pending.count == 1 else { return }  // a flush is already scheduled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.flush() }
    }

    private func flush() {
        lines += pending.map { text in
            nextID += 1
            return Line(id: nextID, text: text)
        }
        pending = []
        // ponytail: keeps only the newest 5,000 lines on screen; Bodega.log has everything.
        if lines.count > 5_000 { lines.removeFirst(lines.count - 5_000) }
    }
}

struct LogView: View {
    @ObservedObject var store: LogStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.lines.isEmpty { Text("brew output appears here") }
                    ForEach(store.lines) { Text($0.text).id($0.id) }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .accessibilityIdentifier("log")
            }
            .onChange(of: store.lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
