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

    init(enabled: Bool = true, multiplier: Int = 2, performance: Bool = true, flowScale: Double = 1.0, bufferMs: Double = 8.0) {
        self.enabled = enabled
        self.multiplier = multiplier
        self.performance = performance
        self.flowScale = flowScale
        self.bufferMs = bufferMs
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

/// ~/Library/Application Support/lsfg-metal/profiles.json: a default, per-game overrides, and
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
    /// folder. Launchers often start a sibling (TLOU Part II lists tlou-ii-l.exe but runs
    /// tlou-ii.exe), and the hook looks its settings up by the name of the running program.
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
