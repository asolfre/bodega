import Foundation

struct Package: Identifiable, Hashable {
    enum Kind: String { case formula, cask }
    let name: String
    /// Every installed version, in the order `brew list --versions` prints them (not sorted).
    let versions: [String]
    let kind: Kind
    var latest: String?
    /// The version in use: the target of `<prefix>/opt/<name>` for formulae. Nil when unknown.
    var active: String?
    var id: String { "\(kind.rawValue):\(name)" }
    var version: String { versions.joined(separator: " ") }
    /// Active version first, then the others, so the version in use is always the first one shown.
    var displayVersions: [String] {
        guard let active, versions.contains(active) else { return versions }
        return [active] + versions.filter { $0 != active }
    }
}

struct BrewResult {
    let status: Int32
    let output: String
}

enum Brew {
    static let path = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/brew"

    /// Runs brew; stdout and stderr are merged so the log shows everything brew says.
    /// `onStart` hands out the process (for Cancel); `onLine` gets each line as brew prints it.
    static func run(_ args: [String],
                    onStart: @MainActor (Process) -> Void = { _ in },
                    onLine: @MainActor (String) -> Void = { _ in }) async -> BrewResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // Set before run() so an early exit cannot be missed; AsyncStream buffers the value.
        let exited = AsyncStream<Int32> { c in
            p.terminationHandler = { c.yield($0.terminationStatus); c.finish() }
        }
        do { try p.run() } catch {
            return BrewResult(status: -1, output: "Failed to launch \(path): \(error)")
        }
        await onStart(p)
        var lines: [String] = []
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                lines.append(line)
                await onLine(line)
            }
        } catch {
            lines.append("Reading brew output failed: \(error)")
        }
        var status: Int32 = -1
        for await s in exited { status = s }
        return BrewResult(status: status, output: lines.joined(separator: "\n"))
    }

    /// stdout only, for JSON commands (brew prints progress on stderr).
    static func json(_ args: [String]) async throws -> [String: Any] {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }.value
    }

    /// The list comes from `brew list --versions` (reads the Cellar/Caskroom), not `brew info --installed`,
    /// which silently drops formulae from untrusted taps.
    static func installed() async throws -> [Package] {
        async let formulae = run(["list", "--formula", "--versions"])
        async let casks = run(["list", "--cask", "--versions"])
        async let outJ = json(["outdated", "--json=v2"])
        let (f, c, outdated) = try await (formulae, casks, outJ)
        guard f.status == 0, c.status == 0 else { throw BrewError(message: f.output + c.output) }

        let latest = parseOutdated(outdated)
        let optDir = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("opt").path
        var pkgs = parseList(f.output, .formula, latest: latest) + parseList(c.output, .cask, latest: latest)
        for i in pkgs.indices where pkgs[i].kind == .formula {
            let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(optDir)/\(pkgs[i].name)")
            pkgs[i].active = link.map { ($0 as NSString).lastPathComponent }
        }
        return pkgs.sorted { $0.name < $1.name }
    }

    /// `brew outdated --json=v2` → "kind:shortname" → newest version.
    /// Outdated names can be tap-qualified (datadog-labs/pack/pup); brew list shows the short name.
    static func parseOutdated(_ json: [String: Any]) -> [String: String] {
        var latest: [String: String] = [:]
        for (kind, key) in [("formula", "formulae"), ("cask", "casks")] {
            for o in json[key] as? [[String: Any]] ?? [] {
                if let n = o["name"] as? String, let short = n.split(separator: "/").last {
                    latest["\(kind):\(short)"] = o["current_version"] as? String
                }
            }
        }
        return latest
    }

    /// One `brew list --versions` line per package: "name v1 v2 …".
    static func parseList(_ out: String, _ kind: Package.Kind, latest: [String: String]) -> [Package] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ").map(String.init)
            guard let name = parts.first else { return nil }
            return Package(name: name, versions: Array(parts.dropFirst()), kind: kind,
                           latest: latest["\(kind.rawValue):\(name)"])
        }
    }
}

struct BrewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
