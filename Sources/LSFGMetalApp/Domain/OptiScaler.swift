import CryptoKit
import Foundation

/// FSR Replacement: OptiScaler (https://github.com/optiscaler/OptiScaler, GPL-3.0) in the game's folder catches the
/// game's FSR 2/3 calls and makes them DLSS calls, which D3DMetal turns into MetalFX, which the hook replaces with NSS
/// (or leaves to MetalFX). Lightscale doesn't ship OptiScaler: it downloads one pinned release from GitHub, checks it,
/// and keeps it in its data folder.
enum OptiScaler {
    static let version = "0.9.4"
    static let download = URL(string: "https://github.com/optiscaler/OptiScaler/releases/download/v0.9.4/Optiscaler_0.9.4-final.20260718._MM.7z")!
    static let sha256 = "575cb4df866116093df75af607e37fd70e10f5163e0f23fd5c804142e80ef0ad"
    static let project = URL(string: "https://github.com/optiscaler/OptiScaler")!

    /// Names OptiScaler loads under, in the order we try them: D3DMetal provides dxgi.dll and d3d12.dll, so those are
    /// out. In a game it takes one the game loads (Windows wouldn't load it otherwise) that the hook doesn't use.
    static let names = ["winmm.dll", "wininet.dll", "winhttp.dll", "dbghelp.dll"]

    static var cache: URL { HookFiles.root.appending(path: "optiscaler/\(version)") }

    /// The first line of the OptiScaler.ini Lightscale writes: marks the copy as ours and says which name it loads as.
    private static func marker(_ name: String) -> String { "; Lightscale: OptiScaler \(version) as \(name)" }

    enum Failure: LocalizedError {
        case download(String)
        case verify
        case unpack(String)
        case noFreeName

        var errorDescription: String? {
            switch self {
            case let .download(why): "Couldn't download OptiScaler: \(why)"
            case .verify: "The OptiScaler download didn't match the expected file, so it wasn't used."
            case let .unpack(why): "Couldn't unpack OptiScaler: \(why)"
            case .noFreeName: "The game doesn't load a DLL OptiScaler can stand in for (\(names.joined(separator: ", "))), or another mod already uses it."
            }
        }
    }

    /// The name Lightscale's OptiScaler loads as in this game, if it's installed there.
    static func installedName(in game: Game) -> String? { installedName(inFolder: game.folder) }

    static func installedName(inFolder folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appending(path: "OptiScaler.ini"), encoding: .utf8),
              let first = text.split(separator: "\n", maxSplits: 1).first,
              let name = names.first(where: { String(first) == marker($0) }),
              FileManager.default.fileExists(atPath: folder.appending(path: name).path) else { return nil }
        return name
    }

    /// The first name OptiScaler can take in the game: one the game loads, free (or OptiScaler's own already), and
    /// not the hook's proxy (winmm.dll can be both).
    static func freeName(in game: Game) -> String? {
        let hook: String? = switch GameScanner.status(exe: game.exe) {
        case let .installed(proxy), let .ready(proxy): proxy.fileName
        case .blocked: nil
        }
        let loaded = GameScanner.imports(of: game.exe)?.imports ?? []
        let ours = installedName(in: game)
        return names.first {
            $0 != hook && loaded.contains($0) && ($0 == ours || !FileManager.default.fileExists(atPath: game.folder.appending(path: $0).path))
        }
    }

    /// Puts OptiScaler next to the game's exe with DLSS as its output, and the DLL override that makes Wine load it.
    static func install(_ game: Game, crossOver: CrossOverInstall) async throws {
        guard let name = freeName(in: game) else { throw Failure.noFreeName }
        if let current = installedName(in: game) {
            guard current != name else { return }
            // under a name the game doesn't load (Lightscale 0.14 and earlier), so it never ran: move it
            try await remove(game, crossOver: crossOver)
        }
        try await ensureDownloaded()
        let fm = FileManager.default
        let ini = try String(contentsOf: cache.appending(path: "OptiScaler.ini"), encoding: .utf8)
            .replacingOccurrences(of: "\nDx12Upscaler=auto", with: "\nDx12Upscaler=dlss")
        try fm.copyItem(at: cache.appending(path: "OptiScaler.dll"), to: game.folder.appending(path: name))
        try (marker(name) + "\n" + ini).write(to: game.folder.appending(path: "OptiScaler.ini"), atomically: true, encoding: .utf8)
        try await crossOver.reg(["add", overrideKey(game), "/v", String(name.dropLast(4)), "/d", "native,builtin", "/f"], in: game.bottle)
    }

    /// Takes Lightscale's OptiScaler out of the game again (someone else's OptiScaler is left alone).
    static func remove(_ game: Game, crossOver: CrossOverInstall?) async throws {
        guard let name = installedName(in: game) else { return }
        let fm = FileManager.default
        for file in [name, "OptiScaler.ini", "OptiScaler.log"] { try? fm.removeItem(at: game.folder.appending(path: file)) }
        try? await crossOver?.reg(["delete", overrideKey(game), "/v", String(name.dropLast(4)), "/f"], in: game.bottle)
    }

    /// Downloads, checks and unpacks the pinned release once (OptiScaler.dll and its default OptiScaler.ini).
    static func ensureDownloaded() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cache.appending(path: "OptiScaler.dll").path) { return }
        let (file, response) = try await URLSession.shared.download(from: download)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        defer { try? fm.removeItem(at: file) }
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw Failure.verify }
        let staging = cache.deletingLastPathComponent().appending(path: ".\(version)-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // macOS's bsdtar (libarchive) reads 7-Zip archives
        let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/bsdtar"), ["-xf", file.path, "-C", staging.path, "OptiScaler.dll", "OptiScaler.ini"])
        guard result.succeeded, fm.fileExists(atPath: staging.appending(path: "OptiScaler.dll").path) else { throw Failure.unpack(result.output) }
        try? fm.removeItem(at: cache)
        try fm.moveItem(at: staging, to: cache)
    }

    private static func overrideKey(_ game: Game) -> String {
        "HKCU\\Software\\Wine\\AppDefaults\\\(game.exe.lastPathComponent)\\DllOverrides"
    }
}
