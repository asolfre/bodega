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
