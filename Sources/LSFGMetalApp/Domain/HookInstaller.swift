import Foundation

/// The built hook files the app installs (bundled in the app's Resources/Hook).
enum HookFiles {
    static let required = ["lsfghook.dll", "lsfghook.so", "lsfghook.placeholder.dll", "liblsfgbridge.dylib",
                           "dinput8.dll", "version.dll"]

    /// Where the built hook files are: the app bundle, LSFG_HOOK_DIR, or hook/build in a checkout.
    static var source: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appending(path: "Hook")) }
        if let dir = ProcessInfo.processInfo.environment["LSFG_HOOK_DIR"] { candidates.append(URL(fileURLWithPath: dir)) }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            candidates.append(d.appending(path: "hook/build"))
            dir = d.deletingLastPathComponent()
        }
        return candidates.first { c in required.allSatisfy { FileManager.default.fileExists(atPath: c.appending(path: $0).path) } }
    }

    /// Shared install location, added to each hooked bottle's DLL search path.
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/lsfg-metal")
    }
    static var builtinDir: URL { root.appending(path: "wine/x86_64-windows") }

    /// Our proxies load "lsfghook.dll" (stored as UTF-16), which identifies them among other mods' DLLs.
    static func isOurProxy(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 1_000_000 else { return false }
        return data.range(of: Data("lsfghook.dll".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) != nil
    }
}

enum InstallError: LocalizedError {
    case hookFilesMissing, crossOverMissing, blocked(String), otherLibPath

    var errorDescription: String? {
        switch self {
        case .hookFilesMissing: "The hook files are missing. Rebuild the app with scripts/build-app.sh."
        case .crossOverMissing: "CrossOver isn't installed."
        case let .blocked(reason): reason
        case .otherLibPath: "This bottle already sets a custom LibPath; add lsfg-metal's folder to it by hand."
        }
    }
}

/// Installs and removes the hook for one game. Same steps and markers as hook/install.sh:
/// 1. hook files in ~/Library/Application Support/lsfg-metal/wine/x86_64-windows
/// 2. a marked [Wine] LibPath block in the bottle's cxbottle.conf
/// 3. a placeholder lsfghook.dll in the bottle's system32
/// 4. the proxy DLL next to the game's exe
/// 5. a per-game DllOverride (<proxy> = native,builtin) in the bottle's registry
enum HookInstaller {
    static let libPathMarker = "lsfg-metal"

    static func install(_ game: Game, crossOver: CrossOverInstall?) async throws {
        guard case let .ready(proxy) = game.status else {
            if case let .blocked(reason) = game.status { throw InstallError.blocked(reason) }
            return
        }
        guard let source = HookFiles.source else { throw InstallError.hookFilesMissing }
        guard let crossOver else { throw InstallError.crossOverMissing }
        let fm = FileManager.default

        try fm.createDirectory(at: HookFiles.builtinDir, withIntermediateDirectories: true)
        for file in ["lsfghook.dll", "lsfghook.so", "liblsfgbridge.dylib"] {
            try replace(HookFiles.builtinDir.appending(path: file), with: source.appending(path: file))
        }
        try setUpBottle(game.bottle, source: source)
        try replace(game.folder.appending(path: proxy.fileName), with: source.appending(path: proxy.fileName))
        try await crossOver.reg(["add", overrideKey(game), "/v", proxy.rawValue, "/d", "native,builtin", "/f"], in: game.bottle)
    }

    /// Removes the game's proxy and override. The bottle setup (LibPath, placeholder) goes too
    /// when no other game in the bottle still uses the hook.
    static func uninstall(_ game: Game, crossOver: CrossOverInstall?, lastInBottle: Bool) async throws {
        guard case let .installed(proxy) = game.status else { return }
        let proxyURL = game.folder.appending(path: proxy.fileName)
        if HookFiles.isOurProxy(proxyURL) { try FileManager.default.removeItem(at: proxyURL) }
        if let crossOver {
            try? await crossOver.reg(["delete", overrideKey(game), "/v", proxy.rawValue, "/f"], in: game.bottle)
        }
        if lastInBottle {
            try? FileManager.default.removeItem(at: game.bottle.system32.appending(path: "lsfghook.dll"))
            try BottleConf(url: game.bottle.conf).removeBlock(libPathMarker)
        }
    }

    static func bottleIsSetUp(_ bottle: Bottle) -> Bool {
        BottleConf(url: bottle.conf).hasBlock(libPathMarker)
            && FileManager.default.fileExists(atPath: bottle.system32.appending(path: "lsfghook.dll").path)
    }

    private static func setUpBottle(_ bottle: Bottle, source: URL) throws {
        let conf = BottleConf(url: bottle.conf)
        if !conf.hasBlock(libPathMarker) {
            let text = (try? String(contentsOf: bottle.conf, encoding: .utf8)) ?? ""
            if text.split(separator: "\n").contains(where: { $0.hasPrefix("\"LibPath\"") }) { throw InstallError.otherLibPath }
            try conf.setBlock(libPathMarker, section: "Wine",
                              lines: ["\"LibPath\" = \"${CX_ROOT}/lib:\(HookFiles.root.path)\""])
        }
        try replace(bottle.system32.appending(path: "lsfghook.dll"), with: source.appending(path: "lsfghook.placeholder.dll"))
    }

    private static func overrideKey(_ game: Game) -> String {
        "HKCU\\Software\\Wine\\AppDefaults\\\(game.exe.lastPathComponent)\\DllOverrides"
    }

    private static func replace(_ destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
}
