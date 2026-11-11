import Foundation
import LSFGCore

/// A compatibility report for a game, for an issue asking to support it: which DLLs its program loads (a proxy
/// for the hook is picked from those), the same for DLLs it loads from its own folder, and what the game's folder
/// holds (engine, other programs, upscalers, other mods' proxy DLLs). Paths are relative to the game's folder,
/// so the user's name and folders stay out of it. The user reads it, copies it and sends it themselves.
enum GameReport {
    /// A new game-support request (not a bug report: the game just isn't compatible yet), report pasted in by the user.
    static func newIssue(for game: Game) -> URL {
        var components = URLComponents(string: "https://github.com/MaximKotliar/lightscale/issues/new")!
        components.queryItems = [URLQueryItem(name: "template", value: "game-support.md"),
                                 URLQueryItem(name: "title", value: "Game support: \(game.name)")]
        return components.url!
    }

    /// DLLs games commonly load that mod loaders also proxy: candidates for the next proxy the hook could use.
    static let possibleProxies: Set<String> = ["winhttp.dll", "wininet.dll", "dsound.dll", "dxgi.dll", "d3d9.dll",
                                               "d3d11.dll", "d3d12.dll", "xinput1_3.dll", "xinput1_4.dll",
                                               "xinput9_1_0.dll", "opengl32.dll", "msacm32.dll", "msvfw32.dll"]

    static func text(for game: Game, crossOver: String?) -> String {
        let root = game.root
        let reason: String = switch game.status {
        case let .installed(proxy): "On (\(proxy.fileName))"
        case let .ready(proxy): "Can take the hook (\(proxy.fileName))"
        case let .blocked(reason): reason
        }
        var lines = [
            "## Compatibility report: \(game.name)",
            "",
            "- **Program:** `\(relative(game.exe, to: root))` (\(game.isCustom ? "added by hand" : "Steam"))",
            "- **Status:** \(reason)",
            "- **Engine:** \(engine(in: root))",
            "- **Upscalers:** \(upscalerFiles(in: root).joined(separator: ", ").ifEmpty("none found"))",
            "",
            "### DLLs \(game.exe.lastPathComponent) loads",
        ]
        lines += linkage(of: game.exe, folder: game.folder)

        let otherMods = ProxyDLL.allCases.map(\.fileName)
            .filter { FileManager.default.fileExists(atPath: game.folder.appending(path: $0).path) && !HookFiles.isOurProxy(game.folder.appending(path: $0)) }
        if !otherMods.isEmpty {
            lines += ["", "Next to the program, not from Lightscale (another mod?): " + otherMods.map { "`\($0)`" }.joined(separator: ", ")]
        }

        let programs = otherPrograms(of: game)
        if !programs.isEmpty {
            lines += ["", "### Other programs in the game's folder", "| Program | Size | Can take the hook |", "|---|---|---|"]
            lines += programs.map { "| `\($0.path)` | \($0.size) | \($0.verdict) |" }
        }
        lines += [
            "",
            "### System",
            "- **Mac:** \(macModel), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- **Lightscale:** \(Updater.currentVersion)",
            "- **CrossOver:** \(crossOver ?? "not found")",
        ]
        return lines.joined(separator: "\n")
    }

    /// The exe's imports, each marked by what it means for the hook, then the imports of DLLs it loads from its
    /// own folder (one level, as the status check reads them).
    static func linkage(of exe: URL, folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe), let info = try? PEFile.info(of: data) else {
            return ["Not a Windows program (no PE header)."]
        }
        let proxies = Set(ProxyDLL.allCases.map(\.fileName))
        func mark(_ dll: String) -> String {
            if proxies.contains(dll) { return "`\(dll)` **proxy the hook can use**" }
            if FileManager.default.fileExists(atPath: folder.appending(path: dll).path) { return "`\(dll)` (in the game's folder)" }
            if possibleProxies.contains(dll) { return "`\(dll)` (possible proxy)" }
            return "`\(dll)`"
        }
        let dlls = info.imports.filter { !$0.hasPrefix("api-ms-win-") && !$0.hasPrefix("ext-ms-") }
        let apiSets = info.imports.count - dlls.count
        var lines = ["\(info.is64Bit ? "64-bit" : "32-bit"), \(dlls.count) DLLs\(apiSets > 0 ? " (and \(apiSets) Windows API sets, left out)" : ""):", ""]
        lines += dlls.map { "- " + mark($0) }
        for dll in dlls where !proxies.contains(dll) {
            let local = folder.appending(path: dll)
            guard let data = try? Data(contentsOf: local, options: .mappedIfSafe), let info = try? PEFile.info(of: data) else { continue }
            let nested = info.imports.filter { !$0.hasPrefix("api-ms-win-") && !$0.hasPrefix("ext-ms-") }
            lines += ["", "`\(dll)` from the game's folder loads: " + nested.map(mark).joined(separator: ", ").ifEmpty("nothing")]
        }
        return lines
    }

    static func engine(in root: URL) -> String {
        let fm = FileManager.default
        func has(_ path: String) -> Bool { fm.fileExists(atPath: root.appending(path: path).path) }
        if has("Engine/Binaries") || has("Engine/Plugins") { return "Unreal Engine" }
        let top = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if top.contains("UnityPlayer.dll") || top.contains(where: { $0.hasSuffix("_Data") }) { return "Unity" }
        if top.contains(where: { $0.lowercased().hasSuffix(".pck") }) { return "Godot (guess)" }
        return "not recognized"
    }

    /// Upscaler libraries anywhere under the game's folder, by file name.
    static func upscalerFiles(in root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var names = Set<String>()
        while let path = walker.nextObject() as? String {
            if walker.level >= 9 { walker.skipDescendants() }
            let name = (path as NSString).lastPathComponent
            if UpscalerTech.matching(fileName: name) != nil { names.insert(name) }
        }
        return names.sorted()
    }

    /// Other .exe files under the game's folder, largest first (at most 20), with whether each can take the hook.
    static func otherPrograms(of game: Game) -> [(path: String, size: String, verdict: String)] {
        guard let walker = FileManager.default.enumerator(atPath: game.root.path) else { return [] }
        var found: [(path: String, bytes: Int)] = []
        while let path = walker.nextObject() as? String {
            if walker.level >= 4 { walker.skipDescendants() }
            guard path.lowercased().hasSuffix(".exe"), let bytes = walker.fileAttributes?[.size] as? Int,
                  game.root.appending(path: path).path != game.exe.path else { continue }
            found.append((path, bytes))
        }
        return found.sorted { $0.bytes > $1.bytes }.prefix(20).map { program in
            let verdict: String = switch GameScanner.status(exe: game.root.appending(path: program.path)) {
            case let .installed(proxy), let .ready(proxy): "yes (\(proxy.fileName))"
            case let .blocked(reason): "no: \(reason)"
            }
            return (program.path, ByteCountFormatter.string(fromByteCount: Int64(program.bytes), countStyle: .file), verdict)
        }
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let prefix = root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
