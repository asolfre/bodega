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
    /// Homebrew's whole catalog for Discover/Install; read again each time it is shown, so a brew update shows up.
    @Published var catalog: [SearchResult]?
    private var cancelled = false

    func loadCatalog() async {
        catalog = await Task.detached { Brew.catalog() }.value
    }

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
        if package != nil, preview.isPlainSingleUpdate {
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

enum SidebarItem: String, Identifiable {
    case installed = "Installed", outdated = "Outdated", pinned = "Pinned"
    case formulae = "Formulae", casks = "Casks", discover = "Discover"
    var id: Self { self }

    var icon: String {
        switch self {
        case .installed: "shippingbox"
        case .outdated: "arrow.up.circle"
        case .pinned: "pin"
        case .formulae: "terminal"
        case .casks: "macwindow"
        case .discover: "plus.magnifyingglass"
        }
    }

    func includes(_ p: Package) -> Bool {
        switch self {
        case .installed, .discover: true
        case .outdated: p.latest != nil
        case .pinned: p.pinned
        case .formulae: p.kind == .formula
        case .casks: p.kind == .cask
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: BrewModel
    @State private var section: SidebarItem? = .installed
    /// One toolbar field: it filters the list, or in Discover it searches Homebrew's catalog as you type.
    @State private var text = ""
    @State private var selection: Set<Package.ID> = []
    @State private var pendingUninstall: Package?
    @State private var discoverSelection: SearchResult.ID?

    var current: SidebarItem { section ?? .installed }

    var shown: [Package] {
        model.packages.filter { current.includes($0) && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") { row(.installed); row(.outdated); row(.pinned) }
                Section("By type") { row(.formulae); row(.casks) }
                Section("Get more") { row(.discover) }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            VSplitView {
                VStack(spacing: 0) {
                    if current == .discover {
                        InstallBrowser(query: text, selection: $discoverSelection) { r in
                            Task { await model.perform("install", r.name, cask: r.kind == .cask) }
                        }
                    } else {
                        table
                    }
                    HStack {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("status")
                        if model.running != nil {
                            Button("Cancel") { model.cancel() }.controlSize(.small)
                                .accessibilityIdentifier("cancel-button")
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 300)

                LogView(store: model.output)
                .frame(minHeight: 100)
            }
            .navigationTitle("Bodega")
            .navigationSubtitle(current.rawValue)
        }
        .frame(minWidth: 860, minHeight: 520)
        .searchable(text: $text, placement: .toolbar,
                    prompt: current == .discover ? "Search all Homebrew packages" : "Filter \(current.rawValue.lowercased())")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.perform(["update"]) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Fetch new versions (brew update)")
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("refresh-button")
                Button { Task { await model.previewCleanup() } } label: { Label("Clean up…", systemImage: "trash") }
                    .help("Remove old versions and caches (brew cleanup)")
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("cleanup-button")
                Button { Task { await model.previewUpgrade() } } label: {
                    Label(outdated == 0 ? "Update all" : "Update all (\(outdated))", systemImage: "arrow.up.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("update-all-button")
            }
        }
        // Not .task: closing the window would cancel it while brew update keeps running.
        .onAppear { Task { await model.refresh(); await model.perform(["update"]) } }
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

    func row(_ item: SidebarItem) -> some View {
        Label(item.rawValue, systemImage: item.icon)
            .badge(item == .discover ? 0 : model.packages.filter(item.includes).count)
            .tag(item)
            .accessibilityIdentifier("sidebar-\(item.rawValue.lowercased())")
    }

    var table: some View {
        Table(shown, selection: $selection) {
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
            TableColumn("") { p in
                HStack {
                    Spacer()
                    if p.latest != nil {
                        Button("Update") { Task { await model.previewUpgrade(p) } }
                            .disabled(p.pinned || model.busy != nil)
                            .accessibilityIdentifier("update-\(p.name)")
                    }
                    Menu { actions(p) } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityIdentifier("actions-\(p.name)")
                }
            }.width(110)
        }
        .contextMenu(forSelectionType: Package.ID.self) { ids in
            if ids.count == 1, let p = model.packages.first(where: { $0.id == ids.first }) { actions(p) }
        }
    }

    /// The row's secondary actions, shared by the ⋯ menu and the right-click menu.
    @ViewBuilder
    func actions(_ p: Package) -> some View {
        Button("Uninstall…") { pendingUninstall = p }
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

    var outdated: Int { model.packages.filter { $0.latest != nil }.count }

    var status: String {
        if let b = model.busy { return b }
        if let e = model.loadError { return e }
        let f = model.packages.filter { $0.kind == .formula }.count
        return "\(f) formulae, \(model.packages.count - f) casks, \(outdated) outdated"
    }
}

/// Homebrew's whole catalog, narrowed by `query` as it changes, with the selected package's details beside it.
/// The first match is selected on every change of `query`, so the panel always shows what Return or Install takes.
struct InstallBrowser: View {
    @EnvironmentObject var model: BrewModel
    let query: String
    @Binding var selection: SearchResult.ID?
    let install: (SearchResult) -> Void

    var installed: Set<String> { Set(model.packages.map { "\($0.kind.rawValue):\($0.name)" }) }
    func isInstalled(_ r: SearchResult) -> Bool { installed.contains("\(r.kind.rawValue):\(r.shortName)") }

    var body: some View {
        let all = model.catalog ?? []
        let results = Brew.match(all, query)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if model.catalog == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if all.isEmpty {
                    Text("Homebrew's package list is not downloaded yet. Click Refresh, then come back.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    Text("No package matches “\(query)”").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("no-results")
                } else {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "\(all.count.formatted()) packages" : "\(results.count.formatted()) of \(all.count.formatted()) packages")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .accessibilityIdentifier("results-count")
                    Table(results, selection: $selection) {
                        TableColumn("Name") { r in Text(r.name).bold().accessibilityIdentifier("result-\(r.id)") }
                            .width(min: 90, ideal: 140)
                        TableColumn("Type") { Text($0.kind.rawValue).foregroundStyle(.secondary) }.width(60)
                        TableColumn("Description") { Text($0.desc).foregroundStyle(.secondary) }
                        TableColumn("") { r in
                            if isInstalled(r) {
                                Text("✓ installed").foregroundStyle(.green).accessibilityIdentifier("installed-\(r.id)")
                            }
                        }.width(80)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            InfoPanel(result: results.first { $0.id == selection }, installed: isInstalled, install: install)
        }
        .task { await model.loadCatalog() }
        .onChange(of: query) { selection = Brew.match(model.catalog ?? [], query).first?.id }
    }
}

/// What a package is, before it is installed: `brew info` for the selection, asked 0.25 s after it settles.
struct InfoPanel: View {
    @EnvironmentObject var model: BrewModel
    let result: SearchResult?
    let installed: (SearchResult) -> Bool
    let install: (SearchResult) -> Void
    @State private var info: PackageInfo?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = result {
                Text(r.name).font(.title3).bold().textSelection(.enabled)
                let desc = r.desc.isEmpty ? info?.desc ?? "" : r.desc
                if !desc.isEmpty { Text(desc).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let info {
                    Grid(alignment: .leading, verticalSpacing: 4) {
                        line("Version", info.version)
                        if let url = URL(string: info.homepage), let host = url.host() {
                            GridRow { Text("Homepage").foregroundStyle(.secondary); Link(host, destination: url) }
                        }
                        line("License", info.license)
                        line("Needs", info.dependencies.isEmpty ? "nothing else" : info.dependencies.joined(separator: ", "))
                        if let compiles = info.compiles {
                            GridRow {
                                Text("This Mac").foregroundStyle(.secondary)
                                Text(compiles ? "builds from source, can take long" : "✓ ready-made bottle")
                                    .foregroundStyle(compiles ? .orange : .green)
                            }
                        }
                    }
                    .font(.callout)
                    if !info.caveats.isEmpty {
                        ScrollView { Text(info.caveats).font(.caption).textSelection(.enabled) }.frame(maxHeight: 120)
                    }
                } else if loading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if installed(r) {
                    Text("Installed").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                } else {
                    Button { install(r) } label: { Text("Install \(r.shortName)").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("install-\(r.id)")
                }
            } else {
                Text("Select a package to see what it is.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .frame(width: 250, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: result?.id) {
            info = nil
            guard let result else { return }
            loading = true
            defer { loading = false }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let fetched = await Brew.info(result)
            if !Task.isCancelled { info = fetched }
        }
    }

    @ViewBuilder
    func line(_ label: String, _ value: String) -> some View {
        if !value.isEmpty { GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
    }
}

@main
struct BodegaApp: App {
    @StateObject private var model = BrewModel()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("Bodega") { ContentView().environmentObject(model) }
            .commands {
                CommandGroup(after: .textEditing) {
                    // .searchFocused needs macOS 15, so ⌘F reaches the toolbar field through AppKit.
                    Button("Find") {
                        (NSApp.keyWindow?.toolbar?.items.first { $0 is NSSearchToolbarItem } as? NSSearchToolbarItem)?
                            .beginSearchInteraction()
                    }
                    .keyboardShortcut("f")
                }
            }
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
                    section("Packages that use it, also upgraded", preview.dependentUpgrades)
                    section("New dependencies that would be installed", preview.newDependencies)
                    section("Deprecated or disabled", preview.deprecated)
                    section("Notes from brew", preview.notes)
                    if let builds = preview.sourceBuilds {
                        if !builds.isEmpty {
                            Text("Homebrew has no ready-made package (bottle) for this Mac for these "
                                 + "\(builds.count) formulae, so they would compile from source. That can take "
                                 + "hours; Cancel in the main window stops it.")
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
