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
    @Published var autoremovePreview: [String]?
    @Published var upgradePreview: UpgradePreview?
    /// False until the first load ends: the table shows a spinner instead of empty rows.
    @Published var loaded = false
    /// Homebrew's whole catalog for Discover/Install; read again each time it is shown, so a brew update shows up.
    @Published var catalog: [SearchResult]?
    /// Session cache for `brew info` caveats keyed by Package.id (empty string = checked, none).
    @Published var caveatsCache: [Package.ID: String] = [:]
    private var cancelled = false
    /// ⌘N with no window open: the window it opens starts on Discover.
    var openOnDiscover = false

    func loadCatalog() async {
        catalog = await Task.detached { Brew.catalog() }.value
    }

    func loadCaveats(_ p: Package) async {
        guard caveatsCache[p.id] == nil, !p.untrusted else { return }
        if let text = await Brew.caveats(p) { caveatsCache[p.id] = text }
    }

    /// When set, every refresh writes the listed packages here so the UI state can be diffed against `brew list`.
    let dumpPath = ProcessInfo.processInfo.environment["BODEGA_DUMP"]

    func refresh() async {
        guard busy == nil else { return }
        busy = "Loading installed packages…"
        defer { busy = nil; loaded = true }
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
        // A failure only shows in the log, so a hidden log opens again.
        if r.status != 0 && !cancelled { UserDefaults.standard.set(true, forKey: "showLog") }
        busy = nil
        await refresh()
        // brew update/upgrade can change caveats or the package list.
        if args.first == "update" || args.first == "upgrade" { caveatsCache.removeAll() }
        if args == ["update"], catalog != nil { await loadCatalog() }
    }

    /// Same as Ctrl-C in a terminal: brew gets SIGINT and cleans up its own half-done work.
    func cancel() {
        guard let running, running.isRunning else { return }
        cancelled = true
        running.interrupt()
    }

    /// `brew cleanup -n` takes about a minute, so it holds the busy guard and exposes Cancel like any action.
    /// stdout only: the "Warning: Skipping …" lines come on stderr and could split a "Would remove" line.
    func previewCleanup() async {
        guard busy == nil else { return }
        busy = "Checking what brew cleanup would remove…"
        cancelled = false
        let out = (try? await Brew.stdout(["cleanup", "-n"], onStart: { self.running = $0 }))?.1 ?? Data()
        running = nil
        busy = nil
        guard !cancelled else { return }
        cleanupPreview = Brew.parseCleanup(String(decoding: out, as: UTF8.self))
    }

    /// Dry run of `brew autoremove` (unneeded dependency formulae) before asking to remove them.
    func previewAutoremove() async {
        guard busy == nil else { return }
        busy = "Checking what brew autoremove would remove…"
        cancelled = false
        let out = (try? await Brew.stdout(["autoremove", "-n"], onStart: { self.running = $0 }))?.1 ?? Data()
        running = nil
        busy = nil
        guard !cancelled else { return }
        autoremovePreview = Brew.parseAutoremove(String(decoding: out, as: UTF8.self))
    }

    /// Shows what the upgrade would really do before it runs. The dry run lists dependencies too
    /// (e.g. one you uninstalled), and the bottle check finds every formula that would compile.
    /// A single-package update with nothing else to it starts straight away.
    func previewUpgrade(_ package: Package? = nil) async {
        var command = ["upgrade"]
        if let package { command += package.kind == .cask ? ["--cask", package.name] : [package.name] }
        await preview(command, single: package != nil)
    }

    /// Same check before an install: it starts straight away unless it brings dependencies, compiles or warns.
    func previewInstall(_ r: SearchResult) async {
        await preview(r.kind == .cask ? ["install", "--cask", r.name] : ["install", r.name], single: true)
    }

    private func preview(_ command: [String], single: Bool) async {
        guard busy == nil else { return }
        busy = "Checking what brew \(command.joined(separator: " ")) would do…"
        cancelled = false
        let preview = await Brew.previewUpgrade(command, onStart: { self.running = $0 },
                                                isCancelled: { self.cancelled })
        running = nil
        busy = nil
        guard !cancelled else { return }
        if single, preview.isPlainSingleUpdate {
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

struct TagLabel: View {
    let tag: Tag

    var body: some View {
        let color: Color = tag.tone == .error ? .red : tag.tone == .warning ? .orange : .secondary
        Text(tag.text).font(.caption2).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.6)))
            .help(tag.help)
    }
}

/// A row of the Installed table. In the tree its id is the path from the top
/// ("formula:cargo-c › formula:libssh2"), so a package several others need gets a row under each.
/// Children are worked out when a row is shown, not for the whole tree up front.
struct TreeRow: Identifiable {
    static let separator = " › "
    let id: String
    let package: Package
    /// All installed packages by id; nil in the flat list (no children).
    let index: [String: Package]?
    let sortOrder: [KeyPathComparator<TreeRow>]

    init(package: Package, index: [String: Package]? = nil, parent: String? = nil,
         sortOrder: [KeyPathComparator<TreeRow>] = []) {
        self.package = package
        self.index = index
        self.sortOrder = sortOrder
        id = parent.map { $0 + Self.separator + package.id } ?? package.id
    }

    var inTree: Bool { index != nil }
    var sortName: String { package.name }
    var sortType: String { package.kind.rawValue }
    var sortInstalled: String { package.displayVersions.first ?? "" }
    var sortLatest: String { package.latest ?? "" }

    var children: [TreeRow]? {
        guard let index else { return nil }
        let path = id.components(separatedBy: Self.separator)
        let kids = package.deps.compactMap { index[$0] }.filter { !path.contains($0.id) }
        guard !kids.isEmpty else { return nil }
        let rows = kids.map { TreeRow(package: $0, index: index, parent: id, sortOrder: sortOrder) }
        return sortOrder.isEmpty ? rows.sorted { $0.sortName < $1.sortName } : rows.sorted(using: sortOrder)
    }

    static func packageID(_ rowID: ID) -> Package.ID { rowID.components(separatedBy: separator).last ?? rowID }
}

struct ContentView: View {
    @EnvironmentObject var model: BrewModel
    @Environment(\.openWindow) private var openWindow
    @State private var section: SidebarItem? = .installed
    /// One toolbar field: it filters the list, or in Discover it searches Homebrew's catalog as you type.
    @State private var text = ""
    @State private var selection: Set<TreeRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\TreeRow.sortName)]
    @State private var showInspector = false
    @State private var pendingUninstall: Package?
    @AppStorage("installedAsTree") private var asTree = false
    @AppStorage("showLog") private var showLog = false

    var current: SidebarItem { section ?? .installed }

    /// The tree only while nothing is typed: a filter shows its matches as a flat list.
    var rows: [TreeRow] {
        guard current == .installed, asTree, text.isEmpty else {
            return shown.map { TreeRow(package: $0) }.sorted(using: sortOrder)
        }
        let index = Dictionary(model.packages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Brew.treeRoots(model.packages)
            .map { TreeRow(package: $0, index: index, sortOrder: sortOrder) }
            .sorted(using: sortOrder)
    }

    var shown: [Package] {
        model.packages.filter { current.includes($0) && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)) }
    }

    var selectedPackage: Package? {
        guard current != .discover, selection.count == 1, let id = selection.first else { return nil }
        return model.packages.first { $0.id == TreeRow.packageID(id) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") { row(.installed); row(.outdated); row(.pinned) }
                Section("By type") { row(.formulae); row(.casks) }
                Section("Get more") { row(.discover) }
            }
            // All 6 items fit well inside minHeight 520; disabling bounce/scroll keeps "Library"
            // from sliding under the titlebar and triggering macOS's dark scrolled-edge hairline.
            .scrollDisabled(true)
            .scrollBounceBehavior(.basedOnSize)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            detailPane
        }
        .onChange(of: selection) { _, new in showInspector = new.count == 1 }
        .frame(minWidth: 860, minHeight: 520)
        .searchable(text: $text, placement: .toolbar,
                    prompt: current == .discover ? "Search all Homebrew packages" : "Filter \(current.rawValue.lowercased())")
        .toolbar { toolbarItems }
        // Not .task: closing the window would cancel it while brew update keeps running.
        .onAppear {
            AppDelegate.reopenWindow = { openWindow(id: "main") }
            if model.openOnDiscover {
                model.openOnDiscover = false
                section = .discover
                DispatchQueue.main.async(execute: BodegaApp.focusSearch)
            }
            if !model.loaded {
                Task { await model.refresh(); await model.perform(["update"]) }
            }
            if model.catalog == nil { Task { await model.loadCatalog() } }
        }
        .focusedSceneValue(\.showDiscover) {
            section = .discover
            DispatchQueue.main.async(execute: BodegaApp.focusSearch)  // after the toolbar shows Discover's field
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
        .alert(model.autoremovePreview?.isEmpty == true ? "Nothing to autoremove" : "Autoremove unused dependencies?",
               isPresented: Binding(get: { model.autoremovePreview != nil },
                                    set: { if !$0 { model.autoremovePreview = nil } }),
               presenting: model.autoremovePreview) { names in
            if !names.isEmpty {
                Button("Autoremove", role: .destructive) { Task { await model.perform(["autoremove"]) } }
            }
            Button(names.isEmpty ? "OK" : "Cancel", role: .cancel) {}
        } message: { names in
            Text(autoremoveMessage(names))
        }
        .confirmationDialog("Uninstall \(pendingUninstall?.name ?? "")?",
                            isPresented: Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } })) {
            Button("Uninstall", role: .destructive) {
                if let p = pendingUninstall { Task { await model.perform("uninstall", p.name, cask: p.kind == .cask) } }
            }
        }
    }

    private var detailPane: some View {
        VSplitView {
            VStack(spacing: 0) {
                if current == .discover {
                    InstallBrowser(query: text)
                } else if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        table
                        if showInspector, let pkg = selectedPackage {
                            Divider()
                            PackageInspector(package: pkg, close: {
                                showInspector = false
                                selection.removeAll()
                            }, onUninstall: {
                                pendingUninstall = pkg
                            })
                            .frame(width: 260)
                        }
                    }
                }
                HStack {
                    if model.busy != nil { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("status")
                    if model.running != nil {
                        Button("Cancel") { model.cancel() }.controlSize(.small)
                            .accessibilityIdentifier("cancel-button")
                    }
                    Spacer()
                    Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                        .buttonStyle(.borderless).controlSize(.small)
                        .accessibilityIdentifier("log-toggle")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .frame(minHeight: 300)

            if showLog {
                LogView(store: model.output)
                    .frame(minHeight: 100)
            }
        }
        .navigationTitle("Bodega")
        .navigationSubtitle(current.rawValue)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            // Always there, off outside Installed: adding and removing it scattered the toolbar and
            // collapsed the search field to an icon.
            Picker("View", selection: $asTree) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Tree", systemImage: "list.bullet.indent").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(current != .installed)
            .help("List, or tree: each package's dependencies under it (Installed only)")
            .accessibilityIdentifier("view-mode")
            Button { Task { await model.perform(["update"]) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Fetch new versions (brew update)")
                .disabled(model.busy != nil)
                .accessibilityIdentifier("refresh-button")
            Button { Task { await model.previewCleanup() } } label: { Label("Clean up…", systemImage: "trash") }
                .help("Remove old versions and caches (brew cleanup)")
                .disabled(model.busy != nil)
                .accessibilityIdentifier("cleanup-button")
            Button { Task { await model.previewAutoremove() } } label: { Label("Autoremove…", systemImage: "xmark.bin") }
                .help("Remove unused dependencies (brew autoremove)")
                .disabled(model.busy != nil)
                .accessibilityIdentifier("autoremove-button")
            Button { Task { await model.previewUpgrade() } } label: {
                Label(outdated == 0 ? "Update all…" : "Update all (\(outdated))…", systemImage: "arrow.up.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil)
            .accessibilityIdentifier("update-all-button")
        }
    }

    private func autoremoveMessage(_ names: [String]) -> String {
        guard !names.isEmpty else { return "No unneeded dependency formulae found." }
        let shown = names.prefix(15).joined(separator: ", ")
        let more = names.count > 15 ? " and \(names.count - 15) more" : ""
        return "brew autoremove would uninstall \(names.count) \(names.count == 1 ? "formula" : "formulae"):\n\n\(shown)\(more)"
    }

    func row(_ item: SidebarItem) -> some View {
        Label(item.rawValue, systemImage: item.icon)
            .badge(item == .discover ? 0 : model.packages.filter(item.includes).count)
            .tag(item)
            .accessibilityIdentifier("sidebar-\(item.rawValue.lowercased())")
    }

    var table: some View {
        let needed = Brew.needed(model.packages)
        return Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { (r: TreeRow) in
                let p = r.package
                HStack(spacing: 4) {
                    Text(p.name).lineLimit(1).truncationMode(.tail)
                    if r.inTree, let n = r.children?.count {
                        Text("\(n) deps").font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                    }
                    if !p.onRequest && !needed.contains(p.id) {
                        TagLabel(tag: Tag(text: "not needed", tone: .warning,
                                          help: "Installed as a dependency; nothing installed needs it now"))
                            .accessibilityIdentifier("not-needed-\(p.name)")
                    }
                    if p.pinned {
                        Image(systemName: "pin.fill").foregroundStyle(.secondary)
                            .accessibilityIdentifier("pinned-\(p.name)")
                    }
                    if p.untrusted {
                        Text("untrusted tap").font(.caption2).foregroundStyle(.orange).lineLimit(1).fixedSize()
                            .accessibilityIdentifier("untrusted-\(p.name)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }.width(min: 180, ideal: 260)
            TableColumn("Type", value: \.sortType) { Text($0.package.kind.rawValue).lineLimit(1) }.width(70)
            TableColumn("Installed", value: \.sortInstalled) { r in
                let v = r.package.displayVersions
                (Text(v.first ?? "")
                 + Text(v.count > 1 ? " " + v.dropFirst().joined(separator: " ") : "").foregroundColor(.secondary))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }.width(min: 90, ideal: 120)
            TableColumn("Latest", value: \.sortLatest) { r in
                let p = r.package
                HStack(spacing: 4) {
                    Text(p.latest ?? "—").foregroundStyle(p.latest == nil ? .secondary : Color.orange)
                        .lineLimit(1).truncationMode(.tail)
                    if p.isDowngrade {
                        TagLabel(tag: Tag(text: "downgrade", tone: .warning,
                                          help: "Homebrew moved this package back to an older version on purpose. "
                                              + "Update installs \(p.latest ?? "") in place of \(p.displayVersions.first ?? "")."))
                            .accessibilityIdentifier("downgrade-\(p.name)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }.width(min: 90, ideal: 120)
            TableColumn("") { r in
                let p = r.package
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
        .contextMenu(forSelectionType: TreeRow.ID.self) { ids in
            if ids.count == 1, let id = ids.first,
               let p = model.packages.first(where: { $0.id == TreeRow.packageID(id) }) { actions(p) }
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
        if !model.loaded { return "Loading installed packages…" }
        let f = model.packages.filter { $0.kind == .formula }.count
        return "\(f) formulae, \(model.packages.count - f) casks, \(outdated) outdated"
    }
}

/// Details for the selected installed package: description, links, tags, dates, tap, dependencies,
/// on-demand caveats from `brew info`, and row actions pinned at the bottom.
struct PackageInspector: View {
    @EnvironmentObject var model: BrewModel
    let package: Package
    let close: () -> Void
    let onUninstall: () -> Void

    private var meta: SearchResult? {
        if let hit = model.catalog?.first(where: { $0.id == package.id }) { return hit }
        guard let path = package.sourcePath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Brew.parseRubyMeta(text, name: package.name, kind: package.kind)
    }

    private var installedDeps: [String] {
        let installed = Dictionary(model.packages.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return package.deps.compactMap { installed[$0] }.sorted()
    }

    private var usedBy: [String] {
        model.packages.filter { $0.deps.contains(package.id) }.map(\.name).sorted()
    }

    private var showUpdatedDate: Bool {
        guard let updated = package.updatedAt else { return false }
        guard let installed = package.installedAt else { return true }
        return updated.timeIntervalSince(installed) > 300
    }

    var body: some View {
        let m = meta
        let needed = Brew.needed(model.packages)
        let caveats = model.caveatsCache[package.id] ?? ""
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.name).font(.title3).bold().textSelection(.enabled)
                            Text(package.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: close) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                .padding(4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close info")
                        .accessibilityIdentifier("inspector-close")
                    }

                    if let desc = m?.desc, !desc.isEmpty {
                        Text(desc).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    let tags = statusTags(needed: needed, metaTags: m?.tags ?? [])
                    if !tags.isEmpty {
                        FlowTags { ForEach(tags, id: \.self) { TagLabel(tag: $0) } }
                    }

                    if let m, !m.homepage.isEmpty || !m.forge.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if let u = URL(string: m.homepage), u.scheme != nil {
                                Link("\(Brew.linkLabel(m.homepage)) ↗", destination: u).help(m.homepage)
                            }
                            if !m.forge.isEmpty, let u = URL(string: m.forge), u.scheme != nil {
                                Link("\(Brew.siteName(m.forge)) ↗", destination: u).help(m.forge)
                            }
                        }
                        .font(.callout)
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("Installed", package.displayVersions.joined(separator: ", "))
                        if let latest = package.latest {
                            GridRow(alignment: .firstTextBaseline) {
                                Text("Latest").foregroundStyle(.secondary)
                                Text(package.isDowngrade ? "\(latest) (downgrade)" : latest)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                        if let d = package.installedAt {
                            row("Installed on", d.formatted(date: .abbreviated, time: .omitted))
                        }
                        if showUpdatedDate, let d = package.updatedAt {
                            row("Updated on", d.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let tap = package.tap { row("Tap", tap) }
                        if let bottle = package.pouredFromBottle {
                            row("Install", bottle ? "Bottle" : "Built from source")
                        }
                        row("Reason", package.onRequest ? "Installed on request" : "Dependency")
                        if !installedDeps.isEmpty { row("Needs", installedDeps.joined(separator: ", ")) }
                        if !usedBy.isEmpty { row("Used by", usedBy.joined(separator: ", ")) }
                    }
                    .font(.callout)

                    if !caveats.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Caveats").font(.caption).bold().foregroundStyle(.secondary)
                            Text(caveats)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .accessibilityIdentifier("inspector-caveats")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            Divider()

            VStack(spacing: 6) {
                if let latest = package.latest {
                    Button { Task { await model.previewUpgrade(package) } } label: {
                        Text("Update to \(latest)").lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(package.pinned || model.busy != nil)
                    .accessibilityIdentifier("inspector-update")
                }
                HStack(spacing: 8) {
                    if package.kind == .formula {
                        Button {
                            Task { await model.perform(package.pinned ? "unpin" : "pin", package.name, cask: false) }
                        } label: {
                            Text(package.pinned ? "Unpin" : "Pin").frame(maxWidth: .infinity)
                        }
                        .disabled(model.busy != nil)
                        .accessibilityIdentifier("inspector-pin")
                    }
                    Button(role: .destructive, action: onUninstall) {
                        Text("Uninstall…").frame(maxWidth: .infinity)
                    }
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("inspector-uninstall")
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("package-inspector")
        .task(id: package.id) {
            guard model.caveatsCache[package.id] == nil, !package.untrusted else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.loadCaveats(package)
        }
    }

    private func statusTags(needed: Set<String>, metaTags: [Tag]) -> [Tag] {
        var out = metaTags
        if !package.onRequest && !needed.contains(package.id) {
            out.append(Tag(text: "not needed", tone: .warning,
                           help: "Installed as a dependency; nothing installed needs it now"))
        }
        if package.pinned { out.append(Tag(text: "pinned", help: "Skipped by Update all")) }
        if package.untrusted { out.append(Tag(text: "untrusted tap", tone: .warning, help: "Tap is not trusted by brew")) }
        return out
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Wraps TagLabel chips onto multiple lines inside narrow inspector widths.
private struct FlowTags: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? 240, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (sub, pt) in zip(subviews, layout(in: bounds.width, subviews: subviews).points) {
            sub.place(at: CGPoint(x: bounds.minX + pt.x, y: bounds.minY + pt.y), proposal: .unspecified)
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, usedW: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxWidth { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            usedW = max(usedW, x - spacing)
            rowH = max(rowH, sz.height)
        }
        return (pts, CGSize(width: usedW, height: y + rowH))
    }
}

/// Homebrew's whole catalog, narrowed by `query` as it changes. Install first shows what brew would do
/// (dependencies, source builds) when there is anything beyond the package itself.
struct InstallBrowser: View {
    @EnvironmentObject var model: BrewModel
    let query: String

    var installed: Set<String> { Set(model.packages.map { "\($0.kind.rawValue):\($0.name)" }) }
    func isInstalled(_ r: SearchResult) -> Bool { installed.contains("\(r.kind.rawValue):\(r.shortName)") }

    func title(_ r: SearchResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(r.name).bold().accessibilityIdentifier("result-\(r.id)")
            Text(r.version).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    func tags(_ r: SearchResult) -> some View {
        ForEach([Tag(text: r.kind.rawValue)] + r.tags, id: \.self) { TagLabel(tag: $0) }
    }


    @ViewBuilder
    func link(_ url: String, _ label: String) -> some View {
        if let u = URL(string: url), u.scheme != nil {
            Link("\(label) ↗", destination: u).lineLimit(1).help(url)
        }
    }

    var body: some View {
        let all = model.catalog ?? []
        let results = Brew.match(all, query)
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
                List(results) { r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            // Tags move under the name when the row is too narrow: the name is never cut off.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 5) { title(r); tags(r) }
                                VStack(alignment: .leading, spacing: 2) { title(r); HStack(spacing: 5) { tags(r) } }
                            }
                            if !r.desc.isEmpty {
                                Text(r.desc).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 1) {
                            link(r.homepage, Brew.linkLabel(r.homepage))
                            if !r.forge.isEmpty { link(r.forge, Brew.siteName(r.forge)) }
                        }
                        .font(.callout)
                        Group {
                            if isInstalled(r) {
                                Text("✓ installed").foregroundStyle(.green).accessibilityIdentifier("installed-\(r.id)")
                            } else {
                                Button("Install") { Task { await model.previewInstall(r) } }
                                    .disabled(model.busy != nil || r.disabled != nil)
                                    .help(r.disabled.map { "brew will not install it: \($0)" } ?? "")
                                    .accessibilityIdentifier("install-\(r.id)")
                            }
                        }
                        .frame(width: 80)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        if let url = URL(string: r.homepage), url.scheme != nil {
                            Button("Open Homepage") { NSWorkspace.shared.open(url) }
                        }
                        if let url = URL(string: r.forge), url.scheme != nil {
                            Button("Open Project Page") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
        .task { await model.loadCatalog() }
    }
}

/// Reopens the main window on Dock click when all windows were closed (without duplicating minimized windows).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var reopenWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && !sender.windows.contains(where: { $0.isMiniaturized }) {
            Task { @MainActor in Self.reopenWindow?() }
        }
        return true
    }
}

@main
struct BodegaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BrewModel()
    init() {
        // macOS waits about 1.8 s before showing a tooltip; the tags explain themselves only there.
        // 800 ms setting = tooltip about 1 s after the pointer stops (measured; AppKit adds about 0.2 s).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 800])
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Bodega", id: "main") { ContentView().environmentObject(model) }
            .commands { BodegaCommands(model: model) }
    }

    /// .searchFocused needs macOS 15, so the toolbar search field is focused through AppKit.
    @MainActor static func focusSearch() {
        (NSApp.keyWindow?.toolbar?.items.first { $0 is NSSearchToolbarItem } as? NSSearchToolbarItem)?
            .beginSearchInteraction()
    }
}

/// The front window's "go to Discover", for ⌘N.
struct ShowDiscoverKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var showDiscover: (() -> Void)? {
        get { self[ShowDiscoverKey.self] }
        set { self[ShowDiscoverKey.self] = newValue }
    }
}

struct BodegaCommands: Commands {
    let model: BrewModel
    @FocusedValue(\.showDiscover) var showDiscover
    @Environment(\.openWindow) var openWindow

    var body: some Commands {
        // ⌘N goes to Discover, so New Bodega Window moves to ⇧⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Bodega Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Discover Packages") {
                if let showDiscover {
                    showDiscover()
                } else {
                    model.openOnDiscover = true
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { BodegaApp.focusSearch() }
                .keyboardShortcut("f")
        }
    }
}

struct UpgradeSheet: View {
    let preview: UpgradePreview
    let done: (_ confirmed: Bool) -> Void
    var install: Bool { preview.command.first == "install" }
    var verb: String { install ? "Install" : "Update" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preview.upgrades.isEmpty ? "Nothing to \(verb.lowercased())"
                 : preview.command.count > 1 ? "\(verb) \(preview.command.last ?? "")?"
                 : "\(verb) \(preview.upgrades.count) packages?")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(install ? "Install" : "Upgrades", preview.upgrades)
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
                    Button(verb) { done(true) }
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
                ForEach(lines, id: \.self) {
                Text($0).font(.system(.caption, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
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

/// Multi-line selectable read-only log backed by NSTextView (SwiftUI's LazyVStack only selects one Text
/// line at a time, while one big SwiftUI Text re-typeset the whole log on every line).
struct LogView: NSViewRepresentable {
    @ObservedObject var store: LogStore

    private static let placeholder = "brew output appears here"
    private static let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    final class Coordinator {
        var firstID = 0
        var lastID = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.setAccessibilityIdentifier("log")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let atBottom = context.coordinator.lastID == 0
            || scroll.contentView.bounds.maxY >= tv.bounds.maxY - 24
        if Self.sync(storage, with: store.lines, firstID: &context.coordinator.firstID,
                     lastID: &context.coordinator.lastID),
           !store.lines.isEmpty, atBottom {
            // Async so layout finishes first (especially when Show Log opens a fresh scroll view).
            DispatchQueue.main.async { tv.scrollToEndOfDocument(nil) }
        }
    }

    /// Incrementally appends new lines and trims dropped ones so selection and layout survive updates.
    @discardableResult
    static func sync(_ storage: NSTextStorage, with lines: [LogStore.Line],
                     firstID: inout Int, lastID: inout Int) -> Bool {
        guard let first = lines.first, let last = lines.last else {
            guard lastID != 0 || storage.length == 0 else { return false }
            storage.setAttributedString(NSAttributedString(string: placeholder, attributes: attrs))
            firstID = 0; lastID = 0
            return true
        }
        if first.id == firstID && last.id == lastID { return false }
        let added = last.id - lastID
        if lastID == 0 || added <= 0 || added >= lines.count {
            storage.setAttributedString(NSAttributedString(string: lines.map(\.text).joined(separator: "\n"),
                                                           attributes: attrs))
        } else {
            let chunk = "\n" + lines.suffix(added).map(\.text).joined(separator: "\n")
            storage.beginEditing()
            storage.append(NSAttributedString(string: chunk, attributes: attrs))
            let dropped = first.id - firstID
            if dropped > 0 {
                let cut = prefixUTF16Length(droppingLines: dropped, in: storage.string)
                storage.deleteCharacters(in: NSRange(location: 0, length: cut))
            }
            storage.endEditing()
        }
        firstID = first.id
        lastID = last.id
        return true
    }

    /// UTF-16 length of the first `count` lines including newlines (handles surrogate pairs like 🍺).
    static func prefixUTF16Length(droppingLines count: Int, in text: String) -> Int {
        guard count > 0 else { return 0 }
        var seen = 0, len = 0
        for unit in text.utf16 {
            len += 1
            if unit == 0x0A {
                seen += 1
                if seen == count { return len }
            }
        }
        return len
    }
}
