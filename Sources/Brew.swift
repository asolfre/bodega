import Foundation

struct Package: Identifiable, Hashable {
    enum Kind: String { case formula, cask }
    let name: String
    let version: String
    let kind: Kind
    var latest: String?
    var id: String { "\(kind.rawValue):\(name)" }
}

struct BrewResult {
    let status: Int32
    let output: String
}

enum Brew {
    static let path = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/brew"

    /// Runs brew off the main thread; stdout and stderr are merged so the log shows everything brew says.
    static func run(_ args: [String]) async -> BrewResult {
        await Task.detached {
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
            do { try p.run() } catch {
                return BrewResult(status: -1, output: "Failed to launch \(path): \(error)")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return BrewResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
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

        // Outdated names can be tap-qualified (datadog-labs/pack/pup); brew list shows the short name.
        var latest: [String: String] = [:]
        for (kind, key) in [("formula", "formulae"), ("cask", "casks")] {
            for o in outdated[key] as? [[String: Any]] ?? [] {
                if let n = o["name"] as? String, let short = n.split(separator: "/").last {
                    latest["\(kind):\(short)"] = o["current_version"] as? String
                }
            }
        }

        func parse(_ out: String, _ kind: Package.Kind) -> [Package] {
            out.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ").map(String.init)
                guard let name = parts.first else { return nil }
                return Package(name: name, version: parts.dropFirst().last ?? "?", kind: kind,
                               latest: latest["\(kind.rawValue):\(name)"])
            }
        }
        return (parse(f.output, .formula) + parse(c.output, .cask)).sorted { $0.name < $1.name }
    }
}

struct BrewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
