import AppKit
import Foundation
import LSFGCore

/// The CrossOver app and the pieces of it the app uses (read-only: nothing in it is changed).
struct CrossOverInstall: Sendable, Hashable {
    let app: URL
    let version: String

    var root: URL { app.appending(path: "Contents/SharedSupport/CrossOver") }
    var wine: URL { root.appending(path: "bin/wine") }

    /// CrossOver wherever it is: the usual places, then wherever Launch Services knows it (renamed or moved copies).
    static var candidateApps: [URL] {
        var apps = LosslessLocator.defaultCrossOverApps
        if let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") { apps.append(known) }
        return apps
    }

    static func find() -> CrossOverInstall? {
        for app in candidateApps where FileManager.default.fileExists(atPath: app.appending(path: "Contents/SharedSupport/CrossOver/bin/wine").path) {
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

    /// Whether D3DMetal turns DLSS into MetalFX in this bottle (CrossOver's per-bottle DLSS setting, which sets
    /// D3DM_ENABLE_METALFX). Without it a game's DLSS option is unavailable and there's nothing for NSS to replace.
    var dlssEnabled: Bool {
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix(";"), line.contains("\"D3DM_ENABLE_METALFX\"") else { return false }
            return line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == "\"1\""
        }
    }

    /// Folders that hold bottles: CrossOver's own (default, its BottlePath setting, CX_BOTTLE_PATH as CXPatcher
    /// sets it), then ones found through Add Game (bottles kept elsewhere, like on an external drive).
    static var roots: [URL] {
        LosslessLocator.bottleRoots(crossOverApps: CrossOverInstall.candidateApps) + AddedBottleFolders.all
    }

    /// The bottle at `folder`, if it is one.
    init?(folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.appending(path: "cxbottle.conf").path) else { return nil }
        url = folder.resolvingSymlinksInPath()
    }

    init(url: URL) { self.url = url }

    /// The bottle a file is inside, found by looking up its folders for a cxbottle.conf.
    static func containing(_ file: URL) -> Bottle? {
        var folder = file.deletingLastPathComponent()
        while folder.path != "/" && !folder.path.isEmpty {
            if let bottle = Bottle(folder: folder) { return bottle }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    static func all() -> [Bottle] {
        let fm = FileManager.default
        var seen = Set<String>()
        return roots.flatMap { root in
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { fm.fileExists(atPath: $0.appending(path: "cxbottle.conf").path) }
                .map { Bottle(url: $0.resolvingSymlinksInPath()) }
        }
        .filter { seen.insert($0.url.path).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Folders of bottles CrossOver keeps where the app doesn't look by itself, remembered once Add Game finds one.
enum AddedBottleFolders {
    private static let key = "bottleFolders"

    static var all: [URL] { (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) } }

    /// Remembers the folder `bottle` is in (its sibling bottles are found too).
    static func add(_ bottle: Bottle) {
        let folder = bottle.url.deletingLastPathComponent().path
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !list.contains(folder) else { return }
        list.append(folder)
        UserDefaults.standard.set(list, forKey: key)
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
