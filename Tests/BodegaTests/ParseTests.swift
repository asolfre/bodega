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
