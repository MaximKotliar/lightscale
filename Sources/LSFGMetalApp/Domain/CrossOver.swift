import Foundation
import LSFGCore

/// The CrossOver app and the pieces of it the app uses (read-only: nothing in it is changed).
struct CrossOverInstall: Sendable, Hashable {
    let app: URL
    let version: String

    var root: URL { app.appending(path: "Contents/SharedSupport/CrossOver") }
    var wine: URL { root.appending(path: "bin/wine") }

    static func find() -> CrossOverInstall? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appending(path: "Applications/CrossOver.app"), URL(fileURLWithPath: "/Applications/CrossOver.app")]
        for app in candidates where FileManager.default.fileExists(atPath: app.appending(path: "Contents/SharedSupport/CrossOver/bin/wine").path) {
            let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return CrossOverInstall(app: app, version: version)
        }
        return nil
    }

    /// Runs `wine reg …` inside a bottle (used for per-game DLL overrides).
    func reg(_ arguments: [String], in bottle: Bottle) async throws {
        try await Shell.check(wine, ["--bottle", bottle.name, "--wait-children", "reg"] + arguments,
                              environment: ["CX_BOTTLE_PATH": bottle.url.deletingLastPathComponent().path])
    }
}

/// A CrossOver bottle (a Wine prefix with a cxbottle.conf).
struct Bottle: Identifiable, Hashable, Sendable {
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var conf: URL { url.appending(path: "cxbottle.conf") }
    var system32: URL { url.appending(path: "drive_c/windows/system32") }

    static func all() -> [Bottle] {
        let fm = FileManager.default
        var seen = Set<String>()
        return LosslessLocator.bottleRoots().flatMap { root in
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appending(path: "cxbottle.conf").path) }
                .map { Bottle(url: $0.resolvingSymlinksInPath()) }
        }
        .filter { seen.insert($0.url.path).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Edits marked blocks in cxbottle.conf. Each block is wrapped in `;; <marker>: begin/end`
/// comment lines, so removing it restores the file byte for byte (same format as hook/install.sh).
struct BottleConf {
    let url: URL

    private func begin(_ marker: String) -> String { ";; \(marker): begin" }
    private func end(_ marker: String) -> String { ";; \(marker): end" }

    func hasBlock(_ marker: String) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").contains { $0 == begin(marker) }
    }

    /// Lines inside the block (without the markers or a section header we added).
    func blockLines(_ marker: String) -> [String] {
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: begin(marker)), let j = lines.firstIndex(of: end(marker)), i < j else { return [] }
        return lines[(i + 1)..<j].filter { !$0.hasPrefix("[") }
    }

    /// Replaces the block's contents, inside `section` (created inside the block if missing).
    func setBlock(_ marker: String, section: String, lines entries: [String]) throws {
        try removeBlock(marker)
        var text = try String(contentsOf: url, encoding: .utf8)
        let backup = url.appendingPathExtension("lsfg-backup")
        if !FileManager.default.fileExists(atPath: backup.path) { try text.write(to: backup, atomically: true, encoding: .utf8) }
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(of: "[\(section)]") {
            lines.insert(contentsOf: [begin(marker)] + entries + [end(marker)], at: i + 1)
            text = lines.joined(separator: "\n")
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += ([begin(marker), "[\(section)]"] + entries + [end(marker)]).joined(separator: "\n") + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func removeBlock(_ marker: String) throws {
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        guard let i = lines.firstIndex(of: begin(marker)), let j = lines.firstIndex(of: end(marker)), i < j else { return }
        lines.removeSubrange(i...j)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
