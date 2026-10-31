import Foundation
import LSFGCore

/// DLLs we can proxy from a game's folder to load the hook. Each forwards all calls to the real one.
enum ProxyDLL: String, CaseIterable, Sendable {
    case dinput8, version

    var fileName: String { "\(rawValue).dll" }
}

/// A Windows game inside a CrossOver bottle, and whether the hook can go into it.
struct Game: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case installed(ProxyDLL)
        case ready(ProxyDLL)
        case blocked(String)
    }

    let name: String
    let bottle: Bottle
    let exe: URL
    var status: Status
    /// Added by hand with Add Game (not found by the Steam scan).
    var isCustom = false

    var id: URL { exe }
    var folder: URL { exe.deletingLastPathComponent() }
    var isInstalled: Bool { if case .installed = status { true } else { false } }
}

enum GameScanner {
    /// Folders in steamapps/common that aren't games.
    private static let notGames: Set<String> = ["Lossless Scaling", "Steamworks Shared", "Steam Controller Configs",
                                                "SteamVR", "Proton Experimental"]
    /// Executables that are tools around a game rather than the game.
    private static var notGameExe: Regex<Substring> { /(?i)crash|unins|setup|redist|launcher|helper|report|prereq|vc_?redist|dxsetup|quickbms|installer|update|benchmark|cefprocess|webhelper|7z/ }
    /// Signs of kernel or online anti-cheat: injecting there risks a ban.
    private static var antiCheat: Regex<Substring> { /(?i)easyanticheat|battleye|beservice|eaanticheat|vanguard|vgk|nprotect|xigncode|anticheat|anti_cheat|denuvo.?anti/ }

    /// Steam games in every bottle.
    static func scan(bottles: [Bottle]) async -> [Game] {
        await withTaskGroup(of: [Game].self) { group in
            for bottle in bottles {
                group.addTask {
                    LosslessLocator.steamLibraries(in: bottle.url).flatMap { library in
                        let common = library.appending(path: "common")
                        let folders = (try? FileManager.default.contentsOfDirectory(at: common, includingPropertiesForKeys: nil)) ?? []
                        return folders.filter { !notGames.contains($0.lastPathComponent) }
                            .compactMap { game(in: $0, bottle: bottle) }
                    }
                }
            }
            var all: [Game] = []
            for await games in group { all += games }
            return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// The main executable of the game folder: the .exe named most like the folder, else the
    /// largest. (Unity and similar engines ship a small launcher exe next to a big player DLL.)
    static func game(in folder: URL, bottle: Bottle) -> Game? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var best: (url: URL, score: Int)?
        var antiCheatFound: String?
        func squashed(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let folderKey = squashed(folder.lastPathComponent)
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent
            if antiCheatFound == nil, name.contains(antiCheat) { antiCheatFound = name }
            guard url.pathExtension.lowercased() == "exe", !name.contains(notGameExe) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, let size = values?.fileSize, size > 100_000 else { continue }
            let exeKey = squashed(url.deletingPathExtension().lastPathComponent)
            let nameMatch = !exeKey.isEmpty && (folderKey.contains(exeKey) || exeKey.contains(folderKey))
            let score = (nameMatch ? 1 << 40 : 0) + size
            if score > (best?.score ?? 0) { best = (url, score) }
        }
        guard let exe = best?.url else { return nil }
        return Game(name: folder.lastPathComponent, bottle: bottle, exe: exe,
                    status: status(exe: exe, antiCheat: antiCheatFound))
    }

    /// A game the user picked by hand (any .exe inside a bottle).
    static func game(exe: URL, bottle: Bottle) -> Game {
        Game(name: exe.deletingPathExtension().lastPathComponent, bottle: bottle, exe: exe,
             status: status(exe: exe, antiCheat: nil))
    }

    static func status(exe: URL, antiCheat: String?) -> Game.Status {
        let folder = exe.deletingLastPathComponent()
        if let proxy = ProxyDLL.allCases.first(where: { HookFiles.isOurProxy(folder.appending(path: $0.fileName)) }) {
            return .installed(proxy)
        }
        if let antiCheat { return .blocked("Anti-cheat (\(antiCheat))") }
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe), let info = try? PEFile.info(of: data) else {
            return .blocked("Not a Windows program")
        }
        guard info.is64Bit else { return .blocked("32-bit game") }
        // The exe's own imports, plus those of DLLs it loads from its folder (e.g. UnityPlayer.dll).
        var imports = Set(info.imports)
        for dll in info.imports {
            let local = folder.appending(path: dll)
            guard !ProxyDLL.allCases.map(\.fileName).contains(dll),
                  let data = try? Data(contentsOf: local, options: .mappedIfSafe),
                  let localInfo = try? PEFile.info(of: data) else { continue }
            imports.formUnion(localInfo.imports)
        }
        let candidates = ProxyDLL.allCases.filter { imports.contains($0.fileName) }
        guard !candidates.isEmpty else { return .blocked("Doesn't load dinput8 or version.dll") }
        // Skip a proxy name another mod already uses in this folder.
        guard let proxy = candidates.first(where: { !FileManager.default.fileExists(atPath: folder.appending(path: $0.fileName).path) }) else {
            return .blocked("Another mod uses \(candidates[0].fileName)")
        }
        return .ready(proxy)
    }
}
