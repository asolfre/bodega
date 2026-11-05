import Foundation
import Testing
@testable import Bodega

@Suite struct ParseTests {
    @Test func severalVersionsKeepBrewOrder() {
        let p = Brew.parseList("openssl@3 3.6.4 3.6.3 3.6.5\njq 1.8.1\n", .formula, latest: [:])
        #expect(p.map(\.name) == ["openssl@3", "jq"])
        #expect(p[0].versions == ["3.6.4", "3.6.3", "3.6.5"])
        #expect(p[0].version == "3.6.4 3.6.3 3.6.5")
    }

    @Test func activeVersionShownFirst() {
        var p = Brew.parseList("openssl@3 3.6.4 3.6.3 3.6.5", .formula, latest: [:])[0]
        p.active = "3.6.5"
        #expect(p.displayVersions == ["3.6.5", "3.6.4", "3.6.3"])
        p.active = "9.9.9"  // a dangling link must not invent a version
        #expect(p.displayVersions == ["3.6.4", "3.6.3", "3.6.5"])
    }

    @Test func emptyListOutput() {
        #expect(Brew.parseList("", .cask, latest: [:]).isEmpty)
    }

    @Test func searchNoMatchIsEmpty() {
        // brew search exits 1 with empty stdout; the error text only goes to stderr (dropped).
        #expect(Brew.parseNames("").isEmpty)
    }

    @Test func searchNamesAndTapQualifiedShortName() {
        let names = Brew.parseNames("derailed/k9s/k9s\nk9s\n")
        #expect(names == ["derailed/k9s/k9s", "k9s"])
        #expect(SearchResult(name: "datadog-labs/pack/pup", kind: .formula).shortName == "pup")
        #expect(SearchResult(name: "firefox@beta", kind: .cask).shortName == "firefox@beta")
    }

    @Test func exactMatchComesFirst() {
        let r = ["as-tree", "tree", "derailed/k9s/k9s"].map { SearchResult(name: $0, kind: .formula) }
        #expect(Brew.exactFirst(r, "Tree").map(\.name) == ["tree", "as-tree", "derailed/k9s/k9s"])
        #expect(Brew.exactFirst(r, "k9s").first?.name == "derailed/k9s/k9s")
    }

    @Test func catalogFromSignedPackageList() {
        let payload = #"{"formulae":{"tree":{"desc":"Display directories as trees"},"as-tree":{}},"casks":{"treesheets":{"desc":"Mind-map editor"}}}"#
        let file = try! JSONSerialization.data(withJSONObject: ["payload": payload, "signatures": []])
        let all = Brew.parseCatalog(file)
        #expect(all.map(\.id) == ["formula:as-tree", "formula:tree", "cask:treesheets"])
        #expect(all[1].desc == "Display directories as trees")
        #expect(Brew.parseCatalog(Data("not json".utf8)).isEmpty)

        // Exact name on top, other name matches next, description-only matches last.
        let m = Brew.match(all + [SearchResult(name: "dirx", kind: .formula, desc: "Tree of folders")], "tree")
        #expect(m.map(\.name) == ["tree", "as-tree", "treesheets", "dirx"])
        #expect(Brew.match(all, "  ").count == 3)

        // A cask with no description shows its display name; fonts say so.
        let named = #"{"casks":{"font-figtree":{"names":["Figtree"]},"wacom-inkspace":{"names":["Wacom Inkspace"],"desc":""}}}"#
        let casks = Brew.parseCatalog(try! JSONSerialization.data(withJSONObject: ["payload": named]))
        #expect(casks.map(\.desc) == ["Figtree (font)", "Wacom Inkspace"])
        #expect(Brew.match(casks, "inkspace").first?.name == "wacom-inkspace")
    }

    @Test func catalogTagsAndLinks() {
        // Shapes as in brew's package list (2026-11). Today is 2026-11-05.
        func e(_ name: String, _ v: [String: Any]) -> SearchResult { e(name, .formula, v) }
        func e(_ name: String, _ kind: Package.Kind, _ v: [String: Any]) -> SearchResult {
            Brew.catalogEntry(name, kind, v, today: "2026-11-05")
        }
        let tree = e("tree", ["stable_version": "2.3.2", "license": "GPL-2.0-or-later", "bottle_checksum": "x",
                              "homepage": "https://oldmanprogrammer.net/source.php?dir=projects/tree",
                              "stable_url_args": ["https://github.com/Old-Man-Programmer/tree/archive/refs/tags/2.3.2.tar.gz"]])
        #expect(tree.version == "2.3.2")
        #expect(tree.tags.map(\.text) == ["GPL-2.0-or-later"])
        #expect(tree.forge == "https://github.com/Old-Man-Programmer/tree")
        #expect(Brew.linkLabel(tree.homepage) == "oldmanprogrammer.net")
        #expect(tree.disabled == nil)

        // Homepage already on GitHub: no second link; it shows owner/repo.
        let fd = e("fd", ["license": [":any_of": ["Apache-2.0", "MIT"]], "bottle_checksum": "x",
                          "homepage": "https://github.com/sharkdp/fd",
                          "stable_url_args": ["https://github.com/sharkdp/fd/archive/refs/tags/v10.5.1.tar.gz"]])
        #expect(fd.tags.map(\.text) == ["Apache-2.0 or MIT"])
        #expect(fd.forge.isEmpty)
        #expect(Brew.linkLabel(fd.homepage) == "github.com/sharkdp/fd")

        // Long licenses are shortened; the full text is the hover text.
        let gcc = e("gcc", ["license": ["GPL-3.0-or-later": [":with": "GCC-exception-3.1"]], "bottle_checksum": "x"])
        #expect(gcc.tags[0] == Tag(text: "GPL-3.0-or-later + exception", help: "GPL-3.0-or-later with GCC-exception-3.1"))
        let abook = e("abook", ["license": [":all_of": ["GPL-3.0-only", "GPL-2.0-or-later", "BSD-2-Clause"]],
                                "bottle_checksum": "x"])
        #expect(abook.tags[0].text == "3 licenses")

        // Deprecation counts once its date has passed; disabling wins over it and blocks Install.
        let old = e("abcde", ["deprecate_args": [":date": "2025-12-08", ":because": ":unmaintained"], "bottle_checksum": "x",
                              "license": "GPL-2.0-or-later"])
        #expect(old.tags.last == Tag(text: "deprecated: unmaintained", tone: .warning,
                                     help: "Deprecated: unmaintained. brew may disable it later."))
        let future = e("openssl@3", ["deprecate_args": [":date": "2030-04-08", ":because": ":unmaintained"],
                                     "bottle_checksum": "x", "license": "Apache-2.0", "keg_only_args": [":versioned_formula"]])
        #expect(future.tags.map(\.text) == ["Apache-2.0", "keg-only"])
        let gone = e("1kc-razer", .cask, ["version": "0.4.10", "desc": "Razer", "homepage": "https://github.com/1kc/razer-macos",
                                          "disable_args": [":date": "2026-09-01", ":because": ":fails_gatekeeper_check"],
                                          "deprecate_args": [":date": "2025-09-01", ":because": ":fails_gatekeeper_check"]])
        #expect(gone.disabled == "fails gatekeeper check")
        #expect(gone.tags.map(\.text) == ["disabled: fails gatekeeper check"])

        // No bottle, service; Rosetta, self-updating, comma version, download on GitHub.
        let fuse = e("bindfs", ["license": "GPL-2.0-or-later", "service_args": [:]])
        #expect(fuse.tags.map(\.text) == ["GPL-2.0-or-later", "no bottle for this Mac", "runs a service"])
        let box = e("86box", .cask, ["version": "6.0,9001", "caveats_rosetta": true, "auto_updates": true,
                                     "homepage": "https://86box.net/",
                                     "url_args": ["https://github.com/86Box/86Box/releases/download/v6.0/86Box.zip"]])
        #expect(box.version == "6.0")
        #expect(box.tags.map(\.text) == ["needs Rosetta", "updates itself"])
        #expect(box.forge == "https://github.com/86Box/86Box")
        #expect(Brew.siteName(box.forge) == "GitHub")
        #expect(Brew.forgeProject("https://codeberg.org/LGFae/awww.git") == "https://codeberg.org/LGFae/awww")
        #expect(Brew.forgeProject("https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz") == nil)
    }

    @Test func installReceipts() {
        // Formula receipt: a list; only direct dependencies count; tap-qualified names become short ids.
        let f = Brew.parseReceipt([
            "installed_on_request": false, "source": ["tap": "homebrew/core"],
            "runtime_dependencies": [
                ["full_name": "libgit2", "version": "1.9.7", "declared_directly": true],
                ["full_name": "llhttp", "version": "9.4.3", "declared_directly": false],
                ["full_name": "someone/tap/libssh2", "version": "1.11.1", "declared_directly": true],
            ],
        ])
        #expect(f == Brew.Receipt(tap: "homebrew/core", deps: ["formula:libgit2", "formula:libssh2"], onRequest: false))
        // Older receipts do not mark direct ones: all of them count.
        #expect(Brew.parseReceipt(["runtime_dependencies": [["full_name": "zstd"], ["full_name": "xz"]]]).deps
                == ["formula:zstd", "formula:xz"])
        // Cask receipt: {"formula": […], "cask": […]}; "{}" when there are none, as for all casks here.
        let c = Brew.parseReceipt(["installed_on_request": true, "runtime_dependencies": [
            "formula": [["full_name": "openssl@4", "declared_directly": true]],
            "cask": [["full_name": "temurin", "declared_directly": true]],
        ]])
        #expect(c.deps == ["formula:openssl@4", "cask:temurin"])
        #expect(Brew.parseReceipt(["runtime_dependencies": [String: Any]()]).deps.isEmpty)
        // No installed_on_request: never called unneeded by mistake.
        #expect(Brew.parseReceipt([:]).onRequest)
    }

    @Test func dependencyTree() {
        func f(_ name: String, _ deps: [String] = [], onRequest: Bool = true) -> Package {
            var p = Package(name: name, versions: ["1"], kind: .formula)
            p.deps = deps.map { "formula:\($0)" }
            p.onRequest = onRequest
            return p
        }
        // cargo-c needs libgit2 and libssh2; libgit2 needs libssh2 too (a diamond); go is a leftover build tool.
        let pkgs = [f("cargo-c", ["libgit2", "libssh2", "gone"]), f("libgit2", ["libssh2"]), f("libssh2", onRequest: false),
                    f("go", onRequest: false), f("jq")]
        #expect(Brew.treeRoots(pkgs).map(\.name) == ["cargo-c", "go", "jq"])
        let needed = Brew.needed(pkgs)
        #expect(pkgs.filter { !$0.onRequest && !needed.contains($0.id) }.map(\.name) == ["go"])  // "not needed"

        let index = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.id, $0) })
        let top = TreeRow(package: pkgs[0], index: index)
        let kids = top.children ?? []
        #expect(kids.map(\.package.name) == ["libgit2", "libssh2"])  // a dependency that is not installed is left out
        #expect(kids.map(\.id) == ["formula:cargo-c › formula:libgit2", "formula:cargo-c › formula:libssh2"])
        let deeper = kids[0].children ?? []
        #expect(deeper.map(\.id) == ["formula:cargo-c › formula:libgit2 › formula:libssh2"])  // libssh2 again, own id
        #expect(TreeRow.packageID(deeper[0].id) == "formula:libssh2")
        #expect(deeper[0].children == nil)
        #expect(TreeRow(package: pkgs[0]).children == nil)  // flat list: no children

        // A cycle (never seen in brew, but a receipt could say so) stops instead of recursing forever.
        let loop = [f("a", ["b"]), f("b", ["a"])]
        let li = Dictionary(uniqueKeysWithValues: loop.map { ($0.id, $0) })
        #expect(TreeRow(package: loop[0], index: li).children?.first?.children == nil)
    }

    @Test func untrustedTapRule() {
        let trust: [String: Any] = ["taps": ["mongodb/brew"], "formulae": ["datadog-labs/pack/pup"]]
        #expect(Brew.isUntrusted(tap: "derailed/k9s", name: "k9s", trust: trust))
        #expect(Brew.isUntrusted(tap: "streamdal/public", name: "plumber", trust: trust))
        #expect(!Brew.isUntrusted(tap: "datadog-labs/pack", name: "pup", trust: trust))           // formula trusted
        #expect(!Brew.isUntrusted(tap: "mongodb/brew", name: "mongodb-community@4.4", trust: trust)) // whole tap
        #expect(!Brew.isUntrusted(tap: "homebrew/core", name: "jq", trust: [:]))                   // official
        #expect(!Brew.isUntrusted(tap: nil, name: "local", trust: [:]))                            // no receipt tap
    }

    @Test func cleanupDryRun() {
        let out = """
        Would remove: /opt/homebrew/Cellar/cmake/4.4.3 (4,159 files, 68.7MB)
        Would remove: /opt/homebrew/Cellar/pcre2/10.47_1 (244 files, 7.2MB)
        ==> This operation would free approximately 17.6GB of disk space.
        Warning: Skipping ada-url: most recent version 4.0.0_1 not installed
        """
        let p = Brew.parseCleanup(out)
        #expect(p.count == 2)
        #expect(p.summary == "This operation would free approximately 17.6GB of disk space.")
        let none = Brew.parseCleanup("Warning: Skipping ada-url: most recent version 4.0.0_1 not installed\n")
        #expect(none.count == 0 && none.summary == nil)
    }

    @Test func upgradeDryRunSections() {
        // Trimmed real `brew upgrade --dry-run` stdout from 2026-10-19 (hint lines kept on purpose).
        let out = """
        ==> Would install 3 dependencies:
        cxxopts   3.3.1
        corepack  0.36.0
        esbuild   0.28.2
        Some casks with `auto_updates true` or `version :latest` may still require `--greedy`,
        `HOMEBREW_UPGRADE_GREEDY` or `HOMEBREW_UPGRADE_GREEDY_CASKS` to be upgraded.
        Hide these hints with `HOMEBREW_NO_ENV_HINTS=1` (see `man brew`).
        ==> Would upgrade 3 outdated packages
        llvm@21                    21.1.8    -> 21.1.8_1
        datadog-labs/pack/pup      1.26.0    -> 2.0.0
        flyway                     13.10.0   -> 13.10.3 (323.8MB)
        ==> 2 homebrew/core formulae that would build from source
        llvm@21
        node
        """
        let p = Brew.parseUpgradeDryRun(out)
        #expect(p.newDependencies == ["cxxopts 3.3.1", "corepack 0.36.0", "esbuild 0.28.2"])
        #expect(p.upgrades == ["llvm@21 21.1.8 -> 21.1.8_1", "datadog-labs/pack/pup 1.26.0 -> 2.0.0",
                               "flyway 13.10.0 -> 13.10.3"])
        #expect(p.dependencyUpgrades.isEmpty)
        #expect(p.sourceBuilds == [])  // brew's own list is ignored; the bottle rule fills it in
        #expect(p.names == ["llvm@21", "datadog-labs/pack/pup", "flyway", "cxxopts", "corepack", "esbuild"])
        #expect(Brew.parseUpgradeDryRun("").upgrades.isEmpty)
    }

    @Test func singlePackageDryRunSeparatesDependencyUpgrades() {
        // Real `brew upgrade --dry-run pnpm` stdout, 2026-10-19.
        let out = """
        ==> Would install 2 dependencies:
        esbuild  0.28.2
        cxxopts  3.3.1
        ==> Would upgrade 5 dependencies:
        simdutf   9.2.0   -> 9.3.0
        ada-url   4.0.0   -> 4.0.0_1
        merve     1.2.2_3 -> 1.2.2_4
        simdjson  5.0.4   -> 5.0.5
        node      26.8.2  -> 26.12.0
        ==> Would upgrade 1 requested outdated package
        pnpm 11.0.6 -> 12.11.2
        ==> 1 homebrew/core formula that would build from source
        pnpm
        """
        let p = Brew.parseUpgradeDryRun(out)
        #expect(p.upgrades == ["pnpm 11.0.6 -> 12.11.2"])
        #expect(p.dependencyUpgrades.map { $0.split(separator: " ")[0] } == ["simdutf", "ada-url", "merve", "simdjson", "node"])
        #expect(p.newDependencies == ["esbuild 0.28.2", "cxxopts 3.3.1"])
    }

    @Test func installDryRun() {
        // Real `brew install --dry-run` stdout (manifest downloads included), formula and cask.
        let plain = Brew.parseUpgradeDryRun("""
        ==> Would install 1 formula:
        tree 2.3.2
        ==> Downloading https://ghcr.io/v2/homebrew/core/tree/manifests/2.3.2
        Already downloaded: /Users/x/Library/Caches/Homebrew/downloads/30c8--tree-2.3.2.bottle_manifest.json
        """, err: "Warning: The following taps are not trusted:\n  derailed/k9s\n")
        #expect(plain.upgrades == ["tree 2.3.2"])
        #expect(plain.newDependencies.isEmpty && plain.notes.isEmpty)
        #expect(plain.isPlainSingleUpdate)

        let deps = Brew.parseUpgradeDryRun("""
        ==> Would install 1 formula:
        gdal 3.13.3_5
        ==> Downloading https://ghcr.io/v2/homebrew/core/gdal/manifests/3.13.3_5-1
        ==> Would install 51 dependencies for gdal:
        aws-crt-cpp    0.44.3
        re2            2025-11-05_2
        """)
        #expect(deps.upgrades == ["gdal 3.13.3_5"])
        #expect(deps.newDependencies == ["aws-crt-cpp 0.44.3", "re2 2025-11-05_2"])
        #expect(deps.names == ["gdal", "aws-crt-cpp", "re2"])
        #expect(!deps.isPlainSingleUpdate)

        let cask = Brew.parseUpgradeDryRun("==> Would install 1 cask:\niterm2\n")
        #expect(cask.upgrades == ["iterm2"])
        #expect(cask.isPlainSingleUpdate)
    }

    @Test func macOS27DryRunWithDependentsDeprecatedAndNotes() {
        // Real `brew upgrade --dry-run node` on macOS 27, 2026-10-19 (stdout, then a stderr excerpt).
        let out = """
        ==> Would upgrade 4 dependencies:
        simdutf   9.2.0   -> 9.3.2
        ada-url   4.0.0   -> 4.0.0_1
        merve     1.2.2_3 -> 1.2.2_4
        simdjson  5.0.4   -> 5.0.5
        ==> Would upgrade 1 requested outdated package
        node 26.8.2 -> 26.12.0 (21.3MB)
        ==> Would upgrade 2 dependents
        codeburn    0.9.24 -> 0.9.27 (8.7MB)
        gemini-cli  0.46.0 -> 0.64.0 (21.5MB)
        ==> 1 Deprecated or disabled package
        gemini-cli (deprecated)
        Some casks with `auto_updates true` or `version :latest` may still require `--greedy`,
        """
        let err = """
        Warning: The following taps are not trusted:
          ankitpokhrel/jira-cli
        Homebrew is currently ignoring formulae, casks and commands
        Warning: pkgconf would be reinstalled due to macOS version mismatch
        """
        let p = Brew.parseUpgradeDryRun(out, err: err)
        #expect(p.upgrades == ["node 26.8.2 -> 26.12.0"])
        #expect(p.dependencyUpgrades.count == 4)
        #expect(p.dependentUpgrades == ["codeburn 0.9.24 -> 0.9.27", "gemini-cli 0.46.0 -> 0.64.0"])
        #expect(p.deprecated == ["gemini-cli (deprecated)"])
        #expect(p.notes == ["pkgconf would be reinstalled due to macOS version mismatch"])
        #expect(p.names.contains("codeburn"))
        #expect(!p.isPlainSingleUpdate)
        var plain = Brew.parseUpgradeDryRun("==> Would upgrade 1 requested outdated package\npup 1.26.0 -> 2.0.0")
        #expect(plain.isPlainSingleUpdate)
        plain.notes = ["pkgconf would be reinstalled due to macOS version mismatch"]
        #expect(!plain.isPlainSingleUpdate)  // brew would change something else too
    }

    @Test func sourceBuildRule() {
        func formula(_ name: String, _ tap: String, _ files: [String]) -> [String: Any] {
            ["name": name, "tap": tap,
             "bottle": ["stable": ["files": Dictionary(uniqueKeysWithValues: files.map { ($0, [String: Any]()) })]]]
        }
        let info: [String: Any] = ["formulae": [
            formula("node", "homebrew/core", ["arm64_tahoe", "arm64_sequoia"]),  // no bottle for sonoma
            formula("esbuild", "homebrew/core", ["arm64_sequoia", "arm64_sonoma"]),
            formula("cowsay", "homebrew/core", ["all"]),                         // bottle for every Mac
            ["name": "pup", "tap": "datadog-labs/pack"],                         // ships a ready-made binary
        ]]
        #expect(Brew.sourceBuilds(info: info, tag: "arm64_sonoma") == ["node"])
        #expect(Brew.sourceBuilds(info: info, tag: "arm64_sequoia").isEmpty)
    }

    @Test func tapQualifiedOutdatedMatchesShortName() {
        let json: [String: Any] = [
            "formulae": [["name": "datadog-labs/pack/pup", "current_version": "2.0.0"]],
            "casks": [["name": "headlamp", "current_version": "0.46.0"]],
        ]
        let latest = Brew.parseOutdated(json)
        let p = Brew.parseList("pup 1.26.0", .formula, latest: latest)
        #expect(p[0].latest == "2.0.0")
        #expect(latest["cask:headlamp"] == "0.46.0")
        #expect(latest["formula:headlamp"] == nil)
    }
}
