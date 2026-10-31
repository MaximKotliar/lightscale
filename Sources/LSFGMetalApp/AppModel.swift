import Foundation
import Observation

/// UI state for the whole app. Work happens in the Domain services; this only sequences it.
@MainActor @Observable
final class AppModel {
    private(set) var status = SystemStatus()
    private(set) var games: [Game] = []
    private(set) var profiles = ProfileFile.load()
    private(set) var live = LiveStats.Snapshot()
    private(set) var isChecking = false
    private(set) var buildProgress: Double?
    private(set) var busyGames: Set<URL> = []
    var selection: Game.ID?
    var showingSetup = false
    var error: String?

    /// Setup runs once; afterwards problems show as a banner instead.
    var hasCompletedSetup: Bool {
        get { access(keyPath: \.hasCompletedSetup); return UserDefaults.standard.bool(forKey: "setupComplete") }
        set { withMutation(keyPath: \.hasCompletedSetup) { UserDefaults.standard.set(newValue, forKey: "setupComplete") } }
    }

    var selectedGame: Game? { games.first { $0.id == selection } }

    func refresh() async {
        isChecking = true
        defer { isChecking = false }
        status = await DependencyChecker.run()
        profiles = ProfileFile.load()
        let bottles = Bottle.all()
        let scanned = await GameScanner.scan(bottles: bottles)
        // Games added by hand, if their .exe is still there and inside a bottle.
        let custom = profiles.custom.map { URL(fileURLWithPath: $0) }
            .filter { exe in FileManager.default.fileExists(atPath: exe.path) && !scanned.contains { $0.exe == exe } }
            .compactMap { exe -> Game? in
                guard let bottle = bottles.first(where: { exe.path.hasPrefix($0.url.path + "/") }) else { return nil }
                var game = GameScanner.game(exe: exe, bottle: bottle)
                game.isCustom = true
                return game
            }
        games = (scanned + custom).sorted(by: Self.order)
        if selection == nil || selectedGame == nil { selection = games.first?.id }
    }

    /// Installed games first, then games that can be installed, then the rest; by name within each.
    private static func order(_ a: Game, _ b: Game) -> Bool {
        func rank(_ g: Game) -> Int {
            switch g.status { case .installed: 0; case .ready: 1; case .blocked: 2 }
        }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    func buildKernels() async {
        guard let dll = status.lossless?.dll, buildProgress == nil else { return }
        buildProgress = 0
        defer { buildProgress = nil }
        do {
            try await ShaderTranslator.translate(dll: dll) { value in
                Task { @MainActor in self.buildProgress = value }
            }
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func install(_ game: Game) async {
        await perform(on: game) { try await HookInstaller.install(game, crossOver: self.status.crossOver) }
    }

    func uninstall(_ game: Game) async {
        let others = games.contains { $0.bottle == game.bottle && $0.isInstalled && $0.exe != game.exe }
        await perform(on: game) {
            try await HookInstaller.uninstall(game, crossOver: self.status.crossOver, lastInBottle: !others)
        }
    }

    /// Adds a game the scan didn't find (any .exe inside a CrossOver bottle).
    func addGame(exe: URL) {
        guard let bottle = Bottle.all().first(where: { exe.path.hasPrefix($0.url.path + "/") }) else {
            error = "That program isn't inside a CrossOver bottle."
            return
        }
        if !games.contains(where: { $0.exe == exe }) {
            var game = GameScanner.game(exe: exe, bottle: bottle)
            game.isCustom = true
            games.append(game)
            games.sort(by: Self.order)
            var updated = profiles
            updated.custom.append(exe.path)
            save(updated)
        }
        selection = exe
    }

    /// Takes a hand-added game off the list (it must be uninstalled first).
    func removeFromList(_ game: Game) {
        guard game.isCustom, !game.isInstalled else { return }
        games.removeAll { $0.exe == game.exe }
        var updated = profiles
        updated.custom.removeAll { $0 == game.exe.path }
        updated.games[ProfileFile.key(for: game)] = nil
        save(updated)
        if selection == game.exe { selection = games.first?.id }
    }

    /// Where Add Game's file picker starts: inside the first bottle's C: drive.
    var addGameStartFolder: URL? {
        Bottle.all().first.map { $0.url.appending(path: "drive_c") }
    }

    // MARK: Profiles

    func profile(for game: Game) -> GameProfile { profiles.profile(for: game) }
    func hasCustomProfile(_ game: Game) -> Bool { profiles.games[ProfileFile.key(for: game)] != nil }

    func setProfile(_ profile: GameProfile, for game: Game) {
        var updated = profiles
        updated.games[ProfileFile.key(for: game)] = profile == updated.default ? nil : profile
        save(updated)
    }

    func resetProfile(for game: Game) {
        var updated = profiles
        updated.games[ProfileFile.key(for: game)] = nil
        save(updated)
    }

    private func save(_ updated: ProfileFile) {
        guard updated != profiles else { return }
        do {
            try updated.save()
            profiles = updated
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Live

    /// Live stats for `game` if it's the game running right now.
    func liveStats(for game: Game) -> LiveStats.Snapshot? {
        guard live.isLive, let process = live.process, process.lowercased() == ProfileFile.key(for: game) else { return nil }
        return live
    }

    func runningGame() -> Game? { games.first { liveStats(for: $0) != nil } }

    /// Polls the hook's log while the window is open.
    func followLive() async {
        while !Task.isCancelled {
            live = await Task.detached(priority: .utility) { LiveStats.read() }.value
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func perform(on game: Game, _ work: @escaping () async throws -> Void) async {
        busyGames.insert(game.exe)
        defer { busyGames.remove(game.exe) }
        do { try await work() } catch { self.error = error.localizedDescription }
        if let i = games.firstIndex(where: { $0.exe == game.exe }) {
            games[i].status = GameScanner.status(exe: game.exe, antiCheat: nil)
        }
    }
}
