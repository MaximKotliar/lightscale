import Foundation
import LSFGCore

/// DLLs we can proxy from a game's folder to load the hook. Each forwards all calls to the real one.
enum ProxyDLL: String, CaseIterable, Sendable {
    case dinput8, version
    /// For games that load neither of the others (Unreal games often import only winmm of the usual three).
    case winmm

    var fileName: String { "\(rawValue).dll" }
}

/// Upscalers a game ships, recognized by their libraries in the game's folder.
enum UpscalerTech: String, CaseIterable, Hashable, Sendable {
    /// NVIDIA DLSS (NGX, or through Streamline). D3DMetal turns it into MetalFX, which the hook can replace with NSS.
    case dlss
    /// AMD FSR 2 / 3.1 / 4 as a separate library (the FidelityFX SDK). Built-in FSR leaves no file to find.
    case fsr
    /// Intel XeSS.
    case xess

    var label: String {
        switch self {
        case .dlss: "DLSS"
        case .fsr: "FSR"
        case .xess: "XeSS"
        }
    }

    static func matching(fileName: String) -> UpscalerTech? {
        let n = fileName.lowercased()
        guard n.hasSuffix(".dll") else { return nil }
        if n.hasPrefix("nvngx_dlss") || n == "sl.dlss.dll" { return .dlss }
        if n.hasPrefix("amd_fidelityfx_") || n.hasPrefix("ffx_fsr") { return .fsr }
        if n.hasPrefix("libxess") { return .xess }
        return nil
    }
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
    /// Upscalers found in the game's folder.
    var upscalers: Set<UpscalerTech> = []
    /// Where the game's programs are searched: its Steam folder, or the folder of an exe added by hand.
    var root: URL

    init(name: String, bottle: Bottle, exe: URL, status: Status, isCustom: Bool = false,
         upscalers: Set<UpscalerTech> = [], root: URL? = nil) {
        self.name = name
        self.bottle = bottle
        self.exe = exe
        self.status = status
        self.isCustom = isCustom
        self.upscalers = upscalers
        self.root = root ?? exe.deletingLastPathComponent()
    }

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

    /// Steam games in every bottle. `chosen` maps a game folder's path to the exe the user picked for it.
    static func scan(bottles: [Bottle], chosen: [String: String] = [:]) async -> [Game] {
        await withTaskGroup(of: [Game].self) { group in
            for bottle in bottles {
                group.addTask {
                    LosslessLocator.steamLibraries(in: bottle.url).flatMap { library in
                        let common = library.appending(path: "common")
                        let folders = (try? FileManager.default.contentsOfDirectory(at: common, includingPropertiesForKeys: nil)) ?? []
                        return folders.filter { !notGames.contains($0.lastPathComponent) }
                            .compactMap { folder in
                                game(in: folder, bottle: bottle, chosen: chosen[folder.path].map { URL(fileURLWithPath: $0) })
                            }
                    }
                }
            }
            var all: [Game] = []
            for await games in group { all += games }
            return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// The main executable of the game folder: the one the user chose, else the .exe named most like
    /// the folder, else the largest. (Unity and similar engines ship a small launcher exe next to a big
    /// player DLL.) When that one can't take the hook, the best one that can is used instead
    /// (GTA V: PlayGTAV.exe only starts the Rockstar Launcher; GTA5_Enhanced.exe is the game).
    static func game(in folder: URL, bottle: Bottle, chosen: URL? = nil) -> Game? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var exes: [(url: URL, score: Int)] = []
        var upscalers: Set<UpscalerTech> = []
        func squashed(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let folderKey = squashed(folder.lastPathComponent)
        for case let url as URL in walker {
            // upscaler libraries can sit deep (Unreal: Plugins/…/Binaries/ThirdParty/Win64); the exe doesn't
            if walker.level > 9 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent
            if let tech = UpscalerTech.matching(fileName: name) { upscalers.insert(tech) }
            guard walker.level <= 4 else { continue }   // the exe doesn't sit that deep
            guard url.pathExtension.lowercased() == "exe", !name.contains(notGameExe) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, let size = values?.fileSize, size > 100_000 else { continue }
            let exeKey = squashed(url.deletingPathExtension().lastPathComponent)
            let nameMatch = !exeKey.isEmpty && (folderKey.contains(exeKey) || exeKey.contains(folderKey))
            let score = (nameMatch ? 1 << 40 : 0) + size
            exes.append((url, score))
        }
        exes.sort { $0.score > $1.score }
        let exe: URL
        if let chosen, fm.fileExists(atPath: chosen.path), chosen.path.hasPrefix(folder.path + "/") {
            exe = chosen
        } else if let first = exes.first?.url {
            exe = status(exe: first) == .blocked(noProxyReason)
                ? exes.first { loadsAProxy($0.url) }?.url ?? first
                : first
        } else {
            return nil
        }
        return Game(name: folder.lastPathComponent, bottle: bottle, exe: exe,
                    status: status(exe: exe), upscalers: upscalers, root: folder)
    }

    /// Upscaler libraries under `folder` (for games added by hand, whose root folder isn't known: the exe's folder).
    static func upscalers(in folder: URL) -> Set<UpscalerTech> {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: Set<UpscalerTech> = []
        for case let url as URL in walker {
            if walker.level > 8 { walker.skipDescendants(); continue }
            if let tech = UpscalerTech.matching(fileName: url.lastPathComponent) { found.insert(tech) }
        }
        return found
    }

    /// A game the user picked by hand (any .exe inside a bottle).
    static func game(exe: URL, bottle: Bottle) -> Game {
        Game(name: exe.deletingPathExtension().lastPathComponent, bottle: bottle, exe: exe,
             status: status(exe: exe), upscalers: upscalers(in: exe.deletingLastPathComponent()))
    }

    /// Programs under `root` the hook can go into, largest first (tools like crash reporters and
    /// uninstallers left out). For Game program, where the user picks the game's exe.
    static func hookableExes(in root: URL, maxLevel: Int = 4) -> [URL] {
        // relative paths, so results keep root's spelling (the URL walker resolves /var to /private/var)
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var found: [(url: URL, size: Int)] = []
        while let relative = walker.nextObject() as? String {
            if walker.level >= maxLevel { walker.skipDescendants() }
            let name = (relative as NSString).lastPathComponent
            guard !name.hasPrefix("."), (name as NSString).pathExtension.lowercased() == "exe",
                  !name.contains(notGameExe), walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  let size = walker.fileAttributes?[.size] as? Int, size > 100_000 else { continue }
            let url = root.appending(path: relative)
            if loadsAProxy(url) { found.append((url, size)) }
        }
        return found.sorted { $0.size > $1.size }.map(\.url)
    }

    /// The exe to use for one the user picked by hand. A pick that can't take the hook is often a
    /// launcher stub (GTA V's PlayGTAV.exe), so the largest exe next to it that can is used instead.
    static func gameExe(forPicked exe: URL) -> URL {
        guard status(exe: exe) == .blocked(noProxyReason) else { return exe }
        return hookableExes(in: exe.deletingLastPathComponent(), maxLevel: 1).first ?? exe
    }

    /// Whether the exe loads a DLL the hook can proxy (even if another mod already took its place).
    static func loadsAProxy(_ exe: URL) -> Bool {
        switch status(exe: exe) {
        case .installed, .ready: true
        case .blocked(let reason): reason.hasPrefix("Another mod")
        }
    }

    static let noProxyReason = "Doesn't load dinput8, version or winmm.dll"

    /// The DLLs an exe loads: its own imports, plus those of DLLs it loads from its folder (e.g. UnityPlayer.dll).
    /// Our proxies and OptiScaler in the folder are skipped, so what's installed there doesn't change the answer.
    static func imports(of exe: URL) -> (is64Bit: Bool, imports: Set<String>)? {
        let folder = exe.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe), let info = try? PEFile.info(of: data) else { return nil }
        let skipped = Set(ProxyDLL.allCases.map(\.fileName) + OptiScaler.names)
        var imports = Set(info.imports)
        for dll in info.imports where !skipped.contains(dll) {
            guard let data = try? Data(contentsOf: folder.appending(path: dll), options: .mappedIfSafe),
                  let localInfo = try? PEFile.info(of: data) else { continue }
            imports.formUnion(localInfo.imports)
        }
        return (info.is64Bit, imports)
    }

    static func status(exe: URL) -> Game.Status {
        let folder = exe.deletingLastPathComponent()
        if let proxy = ProxyDLL.allCases.first(where: { HookFiles.isOurProxy(folder.appending(path: $0.fileName)) }) {
            return .installed(proxy)
        }
        guard let (is64Bit, imports) = imports(of: exe) else { return .blocked("Not a Windows program") }
        guard is64Bit else { return .blocked("32-bit game") }
        let candidates = ProxyDLL.allCases.filter { imports.contains($0.fileName) }
        guard !candidates.isEmpty else { return .blocked(noProxyReason) }
        // Skip a proxy name another mod already uses in this folder. Lightscale's own OptiScaler under the name
        // doesn't count: installing the hook moves it to another name.
        let optiScaler = OptiScaler.installedName(inFolder: folder)
        guard let proxy = candidates.first(where: {
            $0.fileName == optiScaler || !FileManager.default.fileExists(atPath: folder.appending(path: $0.fileName).path)
        }) else {
            return .blocked("Another mod uses \(candidates[0].fileName)")
        }
        return .ready(proxy)
    }
}
