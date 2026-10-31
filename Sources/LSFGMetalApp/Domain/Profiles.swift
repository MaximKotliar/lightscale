import Foundation

/// Frame-generation settings for one game. The hook reads them from profiles.json when the game
/// starts (keyed by the exe name), so changes apply the next time the game launches.
struct GameProfile: Codable, Equatable, Sendable {
    var enabled = true
    var performance = true
    var flowScale = 1.0
    var bufferMs = 8.0
}

/// ~/Library/Application Support/lsfg-metal/profiles.json: a default plus per-game overrides.
struct ProfileFile: Codable, Equatable, Sendable {
    var `default` = GameProfile()
    var games: [String: GameProfile] = [:]

    static var url: URL { HookFiles.root.appending(path: "profiles.json") }

    static func key(for game: Game) -> String { game.exe.lastPathComponent.lowercased() }

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

    func profile(for game: Game) -> GameProfile { games[Self.key(for: game)] ?? self.default }
}
