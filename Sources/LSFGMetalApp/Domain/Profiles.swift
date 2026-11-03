import Foundation

/// Frame-generation settings for one game. The hook reads them from profiles.json (keyed by the
/// exe name) when the game starts and re-reads the file once a second, so changes apply live.
struct GameProfile: Codable, Equatable, Sendable {
    var enabled = true
    /// Frames shown per real frame: 2 or 4.
    var multiplier = 2
    var performance = true
    var flowScale = 1.0
    var bufferMs = 8.0
    /// The GPTK version this game should run with (nil: whichever CrossOver has). The app reads
    /// it; the hook ignores it.
    var gptk: String?
    /// Upscaling when the game uses DLSS (D3DMetal turns it into MetalFX): "metalfx" leaves it to
    /// MetalFX, "nss" runs Arm Neural Super Sampling in its place.
    var upscaler = "metalfx"
    /// NSS quality: "low", "mid" or "high".
    var nssQuality = "mid"

    init(enabled: Bool = true, multiplier: Int = 2, performance: Bool = true, flowScale: Double = 1.0, bufferMs: Double = 8.0, gptk: String? = nil,
         upscaler: String = "metalfx", nssQuality: String = "mid") {
        self.enabled = enabled
        self.multiplier = multiplier
        self.performance = performance
        self.flowScale = flowScale
        self.bufferMs = bufferMs
        self.gptk = gptk
        self.upscaler = upscaler
        self.nssQuality = nssQuality
    }

    // Missing keys (older files) fall back to defaults instead of discarding the profile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameProfile()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        multiplier = try c.decodeIfPresent(Int.self, forKey: .multiplier) ?? d.multiplier
        performance = try c.decodeIfPresent(Bool.self, forKey: .performance) ?? d.performance
        flowScale = try c.decodeIfPresent(Double.self, forKey: .flowScale) ?? d.flowScale
        bufferMs = try c.decodeIfPresent(Double.self, forKey: .bufferMs) ?? d.bufferMs
        gptk = try c.decodeIfPresent(String.self, forKey: .gptk)
        upscaler = try c.decodeIfPresent(String.self, forKey: .upscaler) ?? d.upscaler
        nssQuality = try c.decodeIfPresent(String.self, forKey: .nssQuality) ?? d.nssQuality
    }

    /// Off / 2x / 4x as one value (0, 1, 2) for the slider.
    var level: Int {
        get { enabled ? (multiplier >= 4 ? 2 : 1) : 0 }
        set {
            enabled = newValue > 0
            if newValue > 0 { multiplier = newValue == 2 ? 4 : 2 }
        }
    }
}

/// ~/Library/Application Support/Lightscale/profiles.json: a default, per-game overrides, and
/// games the user added by hand (the hook only reads "default" and "games").
struct ProfileFile: Codable, Equatable, Sendable {
    var `default` = GameProfile()
    var games: [String: GameProfile] = [:]
    /// Paths of .exe files added with Add Game.
    var custom: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.default = try c.decodeIfPresent(GameProfile.self, forKey: .default) ?? GameProfile()
        games = try c.decodeIfPresent([String: GameProfile].self, forKey: .games) ?? [:]
        custom = try c.decodeIfPresent([String].self, forKey: .custom) ?? []
    }

    static var url: URL { HookFiles.root.appending(path: "profiles.json") }

    static func key(for game: Game) -> String { game.exe.lastPathComponent.lowercased() }

    /// Every name the game may run under: its own .exe first, then the other .exe files in its
    /// folder. Older versions stored settings here by .exe name; they're still read as a fallback
    /// and cleared when the game's folder profile is written.
    static func keys(for game: Game) -> [String] {
        let main = key(for: game)
        let folder = game.exe.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { $0.lowercased() }
            .filter { $0.hasSuffix(".exe") && $0 != main }
            .sorted()
        return [main] + siblings
    }

    static func load() -> ProfileFile {
        guard let data = try? Data(contentsOf: url) else { return ProfileFile() }
        return (try? JSONDecoder().decode(ProfileFile.self, from: data)) ?? ProfileFile()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: HookFiles.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    func profile(for game: Game) -> GameProfile {
        Self.keys(for: game).lazy.compactMap { games[$0] }.first ?? self.default
    }

    /// Stores `profile` under every name the game may run as (nil removes it).
    mutating func setProfile(_ profile: GameProfile?, for game: Game) {
        for key in Self.keys(for: game) { games[key] = profile }
    }
}

/// A game's own settings: `.lsfg/profile.json` in the game's folder, next to the proxy DLL. The
/// hook looks for it from the running .exe's folder and up to 3 folders above, so every program
/// in the game (launchers, renamed or helper .exes, subfolders) shares it. It overrides
/// profiles.json, and the hook picks up changes within a second.
enum GameFolderProfile {
    static func url(for game: Game) -> URL { game.folder.appending(path: ".lsfg/profile.json") }

    static func load(for game: Game) -> GameProfile? {
        guard let data = try? Data(contentsOf: url(for: game)) else { return nil }
        return try? JSONDecoder().decode(GameProfile.self, from: data)
    }

    static func save(_ profile: GameProfile, for game: Game) throws {
        let file = url(for: game)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: file, options: .atomic)
    }

    static func remove(for game: Game) {
        let file = url(for: game)
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
