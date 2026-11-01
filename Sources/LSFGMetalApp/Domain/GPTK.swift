import Foundation

/// One Game Porting Toolkit build: D3DMetal (`external/`) plus its matching Wine DirectX
/// modules (`wine/`), laid out like CrossOver's `lib64/apple_gptk`.
struct GPTKVersion: Identifiable, Hashable, Sendable {
    /// D3DMetal's version, e.g. "3.0" or "4.0b3".
    let version: String
    let folder: URL

    var id: String { version }
    var name: String { "GPTK \(version)" }
}

enum GPTKError: LocalizedError {
    case wineRunning
    case notAllowed
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .wineRunning:
            "Quit Steam and every game in CrossOver first. They use the current GPTK while they run."
        case .notAllowed:
            "macOS didn't let LSFG Metal change CrossOver. Allow it in System Settings → Privacy & Security → App Management, then try again."
        case let .incomplete(version):
            "GPTK \(version) in this app is incomplete. Rebuild the app."
        }
    }
}

/// Switches the GPTK that CrossOver uses. CrossOver loads it from inside its own app for every
/// bottle, so a switch applies to all games. The versions come bundled in the app
/// (scripts/build-app.sh copies them in); a version CrossOver had that the app doesn't carry is
/// saved before it's replaced, so it stays selectable.
enum GPTK {
    /// Where D3DMetal keeps its version, relative to a GPTK folder.
    private static let infoPlist = "external/D3DMetal.framework/Versions/A/Resources/Info.plist"
    private static let parts = ["external", "wine"]

    static func version(of folder: URL) -> String? {
        guard let info = NSDictionary(contentsOf: folder.appending(path: infoPlist)) else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    static func folder(in crossOver: CrossOverInstall) -> URL { crossOver.root.appending(path: "lib64/apple_gptk") }

    static func installed(in crossOver: CrossOverInstall) -> String? { version(of: folder(in: crossOver)) }

    /// Versions bundled with the app (or in LSFG_GPTK_DIR when run from a checkout).
    static var bundledRoot: URL? {
        if let dir = ProcessInfo.processInfo.environment["LSFG_GPTK_DIR"] { return URL(fileURLWithPath: dir) }
        return Bundle.main.resourceURL?.appending(path: "GPTK")
    }

    /// Copies of versions CrossOver had before a switch, when the app doesn't carry them.
    static var savedRoot: URL { HookFiles.root.appending(path: "gptk") }

    /// Every version the app can switch to, newest first.
    static func available() -> [GPTKVersion] { available(in: [bundledRoot, savedRoot].compactMap { $0 }) }

    /// Versions in `roots` (one subfolder each); the first root wins when two have the same version.
    static func available(in roots: [URL]) -> [GPTKVersion] {
        var seen = Set<String>()
        return roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .compactMap { folder in version(of: folder).map { GPTKVersion(version: $0, folder: folder) } }
        }
        .filter { seen.insert($0.version).inserted }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// True while any Wine process runs (Steam, a game, or CrossOver's background server).
    static func isWineRunning() async -> Bool {
        let result = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-x", "wineserver"])
        return result?.succeeded == true
    }

    /// Replaces CrossOver's GPTK with `target`. The new files are copied next to the old ones
    /// first and swapped in by renaming, so a failed copy leaves CrossOver working.
    static func install(_ target: GPTKVersion, into crossOver: CrossOverInstall, available: [GPTKVersion]) async throws {
        guard !(await isWineRunning()) else { throw GPTKError.wineRunning }
        try await install(target, at: folder(in: crossOver), available: available, saveTo: savedRoot)
    }

    /// The switch itself, into CrossOver's `apple_gptk` folder `dst`.
    static func install(_ target: GPTKVersion, at dst: URL, available: [GPTKVersion], saveTo savedRoot: URL) async throws {
        let fm = FileManager.default
        guard parts.allSatisfy({ fm.fileExists(atPath: target.folder.appending(path: $0).path) }) else {
            throw GPTKError.incomplete(target.version)
        }

        // Fail before touching anything if macOS won't let us write into CrossOver.app.
        let probe = dst.appending(path: ".lsfg-write-test")
        guard fm.createFile(atPath: probe.path, contents: Data()) else { throw GPTKError.notAllowed }
        try? fm.removeItem(at: probe)

        // Keep the version CrossOver has now if the app has no copy of it.
        if let current = version(of: dst), !available.contains(where: { $0.version == current }) {
            let saved = savedRoot.appending(path: current)
            try fm.createDirectory(at: saved, withIntermediateDirectories: true)
            for part in parts { try await ditto(dst.appending(path: part), saved.appending(path: part)) }
        }

        for part in parts {
            let new = dst.appending(path: ".lsfg-new-\(part)")
            try? fm.removeItem(at: new)
            try await ditto(target.folder.appending(path: part), new)
        }
        for part in parts {
            let live = dst.appending(path: part), old = dst.appending(path: ".lsfg-old-\(part)")
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: old) }
            try fm.moveItem(at: dst.appending(path: ".lsfg-new-\(part)"), to: live)
            try? fm.removeItem(at: old)
        }
    }

    /// ditto keeps Apple's code signatures and extended attributes intact.
    private static func ditto(_ from: URL, _ to: URL) async throws {
        let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), [from.path, to.path])
        guard result.succeeded else {
            if result.output.contains("Operation not permitted") { throw GPTKError.notAllowed }
            throw ShellError.failed(command: "ditto", output: result.output)
        }
    }
}
