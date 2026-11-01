import Foundation
import Observation

/// UI state for the whole app. Work happens in the Domain services; this only sequences it.
@MainActor @Observable
final class AppModel {
    private(set) var status = SystemStatus()
    private(set) var games: [Game] = []
    private(set) var profiles = ProfileFile.load()
    /// Each game's own settings from its folder (`.lsfg/profile.json`), when it has any.
    private(set) var folderProfiles: [Game.ID: GameProfile] = [:]
    private(set) var live = LiveStats.Snapshot()
    private(set) var isChecking = false
    private(set) var buildProgress: Double?
    private(set) var busyGames: Set<URL> = []
    /// GPTK versions the app can switch CrossOver to, and the one CrossOver has now.
    private(set) var gptkVersions: [GPTKVersion] = []
    private(set) var installedGPTK: String?
    private(set) var isSwitchingGPTK = false
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
        refreshGPTK()
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
        folderProfiles = Dictionary(uniqueKeysWithValues: games.compactMap { game in
            GameFolderProfile.load(for: game).map { (game.id, $0) }
        })
        // Move settings older versions kept in profiles.json (by .exe name) into the game folders.
        for game in games where folderProfiles[game.id] == nil
            && ProfileFile.keys(for: game).contains(where: { profiles.games[$0] != nil }) {
            setProfile(profiles.profile(for: game), for: game)
        }
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
            folderProfiles[game.id] = GameFolderProfile.load(for: game)
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
        updated.setProfile(nil, for: game)
        save(updated)
        GameFolderProfile.remove(for: game)
        folderProfiles[game.id] = nil
        if selection == game.exe { selection = games.first?.id }
    }

    /// Where Add Game's file picker starts: inside the first bottle's C: drive.
    var addGameStartFolder: URL? {
        Bottle.all().first.map { $0.url.appending(path: "drive_c") }
    }

    // MARK: GPTK

    private func refreshGPTK() {
        gptkVersions = GPTK.available()
        installedGPTK = status.crossOver.flatMap(GPTK.installed(in:))
    }

    /// Puts `version` into CrossOver (for every game; Steam must be closed).
    func switchGPTK(to version: GPTKVersion) async {
        guard let crossOver = status.crossOver, !isSwitchingGPTK else { return }
        isSwitchingGPTK = true
        defer { isSwitchingGPTK = false }
        do {
            try await GPTK.install(version, into: crossOver, available: gptkVersions)
        } catch {
            self.error = error.localizedDescription
        }
        refreshGPTK()
    }

    // MARK: Profiles

    func profile(for game: Game) -> GameProfile { folderProfiles[game.id] ?? profiles.profile(for: game) }

    func hasCustomProfile(_ game: Game) -> Bool {
        folderProfiles[game.id] != nil || ProfileFile.keys(for: game).contains { profiles.games[$0] != nil }
    }

    /// Saves the game's settings in its folder (removed when they match the defaults).
    func setProfile(_ profile: GameProfile, for game: Game) {
        // Settings saved by .exe name in profiles.json by older versions would otherwise come back.
        var updated = profiles
        updated.setProfile(nil, for: game)
        save(updated)
        if profile == profiles.default {
            GameFolderProfile.remove(for: game)
            folderProfiles[game.id] = nil
            return
        }
        do {
            try GameFolderProfile.save(profile, for: game)
            folderProfiles[game.id] = profile
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetProfile(for game: Game) { setProfile(profiles.default, for: game) }

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
        guard live.isLive, let process = live.process, ProfileFile.keys(for: game).contains(process.lowercased()) else { return nil }
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
