import AppKit
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
    private(set) var busyGames: Set<URL> = []
    /// Games whose FSR goes through Lightscale's OptiScaler (FSR replacement) instead of DLSS.
    private(set) var fsrPathGames: Set<URL> = []
    /// GPTK versions the app can switch CrossOver to, and the one CrossOver has now.
    private(set) var gptkVersions: [GPTKVersion] = []
    private(set) var installedGPTK: String?
    private(set) var isSwitchingGPTK = false
    /// A newer version of the app on GitHub, once a check found one.
    private(set) var appUpdate: AppRelease?
    private(set) var isInstallingAppUpdate = false
    /// Shown once, after a check the user asked for ("up to date").
    var notice: String?
    /// Hooked games run an older hook than this app ships (it was updated since they were installed).
    private(set) var hookUpdateAvailable = false
    private(set) var isUpdatingHook = false
    /// The bundled hook's version, hashed once per launch.
    private var bundledHookVersion: String?
    var selection: Game.ID?
    /// Game Mode and the cursor fix while a hooked game runs.
    let playSession = PlaySession()
    var showingSetup = false
    var error: String?

    /// Setup runs once; afterwards problems show as a banner instead.
    var hasCompletedSetup: Bool {
        get {
            access(keyPath: \.hasCompletedSetup)
            return UserDefaults.standard.bool(forKey: "setupComplete")
        }
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
        let scanned = await GameScanner.scan(bottles: bottles, chosen: profiles.exes)
        // Games added by hand, if their .exe is still there and has a bottle (the one it's in, or the one
        // picked for it). A launcher picked before Add Game looked past launchers is swapped for the game's exe.
        var updated = profiles
        for path in profiles.custom {
            let exe = GameScanner.gameExe(forPicked: URL(fileURLWithPath: path)).path
            if exe != path { updated.renameCustom(path, to: exe) }
        }
        save(updated)
        let custom = profiles.custom.map { URL(fileURLWithPath: $0) }
            .filter { exe in FileManager.default.fileExists(atPath: exe.path) && !scanned.contains { $0.exe == exe } }
            .compactMap { exe -> Game? in
                guard let bottle = bottle(for: exe, among: bottles) else { return nil }
                var game = GameScanner.game(exe: exe, bottle: bottle)
                game.isCustom = true
                return game
            }
        games = (scanned + custom).sorted(by: Self.order)
        exeChoices = [:]
        // Lightscale's OptiScaler under a name the game doesn't load (0.14 and earlier) never ran: move it to one it
        // does. The misplaced copy was never loaded, so this is safe even while the game runs.
        if let crossOver = status.crossOver {
            for game in games {
                guard let current = OptiScaler.installedName(in: game) else { continue }
                let name = OptiScaler.freeName(in: game)
                guard current != name else { continue }
                do {
                    // no name the game loads is free: take it out rather than leave a copy that never runs
                    if name == nil { try await OptiScaler.remove(game, crossOver: crossOver) }
                    else { try await OptiScaler.install(game, crossOver: crossOver) }
                } catch { self.error = error.localizedDescription }
            }
        }
        fsrPathGames = Set(games.filter { OptiScaler.installedName(in: $0) != nil }.map(\.exe))
        folderProfiles = Dictionary(uniqueKeysWithValues: games.compactMap { game in
            GameFolderProfile.load(for: game).map { (game.id, $0) }
        })
        // Move settings older versions kept in profiles.json (by .exe name) into the game folders.
        for game in games where folderProfiles[game.id] == nil
            && ProfileFile.keys(for: game).contains(where: { profiles.games[$0] != nil }) {
            setProfile(profiles.profile(for: game), for: game)
        }
        if selection == nil || selectedGame == nil { selection = games.first?.id }
        await checkHookVersion()
    }

    private func checkHookVersion() async {
        if bundledHookVersion == nil, let source = HookFiles.source {
            bundledHookVersion = await Task.detached(priority: .utility) { HookFiles.version(of: source) }.value
        }
        guard let bundled = bundledHookVersion else { hookUpdateAvailable = false; return }
        hookUpdateAvailable = games.contains { $0.isInstalled } && HookFiles.installedVersion != bundled
    }

    // MARK: App updates

    /// Checks GitHub Releases at launch and every six hours while the app runs.
    func followAppUpdates() async {
        while !Task.isCancelled {
            await checkForAppUpdate(userInitiated: false)
            try? await Task.sleep(for: .seconds(6 * 3600))
        }
    }

    func checkForAppUpdate(userInitiated: Bool) async {
        do {
            appUpdate = try await Updater.newerRelease()
            if userInitiated, appUpdate == nil { notice = "\(AppName.display) \(Updater.currentVersion) is the newest version." }
        } catch {
            if userInitiated { self.error = "Couldn't check for updates: \(error.localizedDescription)" }
        }
    }

    /// Downloads and verifies the update, then quits; the new version opens by itself.
    func installAppUpdate() async {
        guard let release = appUpdate, !isInstallingAppUpdate else { return }
        isInstallingAppUpdate = true
        defer { isInstallingAppUpdate = false }
        do {
            let newApp = try await Updater.prepare(release)
            try Updater.installOnQuit(newApp)
            NSApplication.shared.terminate(nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reinstalls the hook for every game that has it: the shared files and each game's proxy. Not while one of them
    /// runs, since it has the hook loaded.
    func updateHooks() async {
        if let running = runningGame() {
            error = "Quit \(running.name) first: it has the hook loaded."
            return
        }
        isUpdatingHook = true
        defer { isUpdatingHook = false }
        for game in games where game.isInstalled { await install(game) }
        await checkHookVersion()
    }

    /// Installed games first, then games that can be installed, then the rest; by name within each.
    private static func order(_ a: Game, _ b: Game) -> Bool {
        func rank(_ g: Game) -> Int {
            switch g.status { case .installed: 0; case .ready: 1; case .blocked: 2 }
        }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    func install(_ game: Game) async {
        await perform(on: game) { try await HookInstaller.install(game, crossOver: self.status.crossOver) }
        await checkHookVersion()
    }

    func uninstall(_ game: Game) async {
        let others = games.contains { $0.bottle == game.bottle && $0.isInstalled && $0.exe != game.exe }
        await perform(on: game) {
            try await OptiScaler.remove(game, crossOver: self.status.crossOver)
            try await HookInstaller.uninstall(game, crossOver: self.status.crossOver, lastInBottle: !others)
        }
        refreshFSRPath(game)
    }

    /// Which of the game's upscalers Lightscale replaces: its DLSS (as D3DMetal hands it over), or its FSR (OptiScaler
    /// in the game's folder turns FSR into DLSS first). The MetalFX/NSS choice stays the same either way.
    func setReplacesFSR(_ fsr: Bool, for game: Game) async {
        guard fsr != fsrPathGames.contains(game.exe) else { return }
        if runningGame()?.exe == game.exe {
            error = "Quit \(game.name) first: its folder can't change while it runs."
            return
        }
        await perform(on: game) {
            if fsr {
                guard let crossOver = self.status.crossOver else { throw InstallError.crossOverMissing }
                try await OptiScaler.install(game, crossOver: crossOver)
            } else {
                try await OptiScaler.remove(game, crossOver: self.status.crossOver)
            }
        }
        refreshFSRPath(game)
    }

    private func refreshFSRPath(_ game: Game) {
        if OptiScaler.installedName(in: game) != nil { fsrPathGames.insert(game.exe) } else { fsrPathGames.remove(game.exe) }
    }

    /// The bottle that runs a game added by hand: the one its exe is in, else the one picked for it.
    private func bottle(for exe: URL, among bottles: [Bottle]) -> Bottle? {
        if let inside = bottles.first(where: { exe.path.hasPrefix($0.url.path + "/") }) { return inside }
        return profiles.customBottles[exe.path].flatMap { Bottle(folder: URL(fileURLWithPath: $0)) }
    }

    /// A game picked with Add Game from outside every bottle, waiting for the user to say which bottle runs it.
    struct PendingGame: Identifiable, Equatable {
        let exe: URL
        let bottles: [Bottle]
        var id: URL { exe }
    }

    var pendingGame: PendingGame?

    /// The game whose compatibility report is open.
    var reportGame: Game?

    /// Adds a game the scan didn't find: any .exe. One inside a bottle runs there; for one elsewhere on the
    /// Mac (games kept outside bottles, like on an external drive) the only bottle is used, or the user picks.
    func addGame(exe picked: URL) {
        let exe = GameScanner.gameExe(forPicked: picked)
        if exe != picked {
            notice = "\(picked.lastPathComponent) only starts the game, so \(exe.lastPathComponent) from the same folder was added instead."
        }
        if games.contains(where: { $0.exe == exe }) { selection = exe; return }
        let bottles = Bottle.all()
        if let inside = bottles.first(where: { exe.path.hasPrefix($0.url.path + "/") }) {
            add(exe, bottle: inside, linked: false)
        } else if let found = Bottle.containing(exe) {
            AddedBottleFolders.add(found)   // a bottle CrossOver keeps where the app doesn't look
            add(exe, bottle: found, linked: false)
        } else if bottles.count == 1 {
            add(exe, bottle: bottles[0], linked: true)
        } else {
            pendingGame = PendingGame(exe: exe, bottles: bottles)
        }
    }

    /// Adds the pending game to run in `bottle`.
    func addPendingGame(in bottle: Bottle) {
        guard let pending = pendingGame else { return }
        pendingGame = nil
        add(pending.exe, bottle: bottle, linked: true)
    }

    /// Adds the pending game to run in the bottle at `folder` (one the app didn't know of).
    func addPendingGame(bottleFolder folder: URL) {
        guard let bottle = Bottle(folder: folder) else {
            pendingGame = nil
            error = "That folder isn't a CrossOver bottle (it has no cxbottle.conf). In CrossOver, right-click the bottle and choose Show in Finder to find it."
            return
        }
        AddedBottleFolders.add(bottle)
        addPendingGame(in: bottle)
    }

    private func add(_ exe: URL, bottle: Bottle, linked: Bool) {
        var game = GameScanner.game(exe: exe, bottle: bottle)
        game.isCustom = true
        games.append(game)
        games.sort(by: Self.order)
        folderProfiles[game.id] = GameFolderProfile.load(for: game)
        var updated = profiles
        updated.custom.append(exe.path)
        if linked { updated.customBottles[exe.path] = bottle.url.path }
        save(updated)
        selection = exe
    }

    /// Programs in the game's folder the hook can go into, for Game program (searched on first look).
    private(set) var exeChoices: [Game.ID: [URL]] = [:]

    func loadExeChoices(for game: Game) async {
        guard exeChoices[game.id] == nil else { return }
        let root = game.root
        let found = await Task.detached(priority: .userInitiated) { GameScanner.hookableExes(in: root) }.value
        exeChoices[game.id] = found
    }

    /// Makes `exe` the game's program (the hook goes next to it). Only while the hook isn't installed.
    func chooseExe(_ exe: URL, for game: Game) {
        guard exe != game.exe, !game.isInstalled,
              let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = profiles
        if game.isCustom {
            guard !games.contains(where: { $0.exe == exe }) else { selection = exe; return }
            updated.renameCustom(game.exe.path, to: exe.path)
            var new = GameScanner.game(exe: exe, bottle: game.bottle)
            new.isCustom = true
            games[i] = new
        } else {
            updated.exes[game.root.path] = exe.path
            guard let new = GameScanner.game(in: game.root, bottle: game.bottle, chosen: exe) else { return }
            games[i] = new
        }
        save(updated)
        let new = games[i]
        exeChoices[new.id] = exeChoices[game.id]
        folderProfiles[new.id] = GameFolderProfile.load(for: new)
        selection = new.id
    }

    /// Takes a hand-added game off the list (it must be uninstalled first).
    func removeFromList(_ game: Game) {
        guard game.isCustom, !game.isInstalled else { return }
        games.removeAll { $0.exe == game.exe }
        var updated = profiles
        updated.custom.removeAll { $0 == game.exe.path }
        updated.customBottles[game.exe.path] = nil
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

    /// Polls the hook's log once a second, from launch.
    func followLive() async {
        while !Task.isCancelled {
            live = await Task.detached(priority: .utility) { LiveStats.read() }.value
            if let game = runningGame(), let pid = live.samples.last?.pid {
                let p = profile(for: game)
                playSession.update(.init(pid: pid_t(pid), gameMode: p.gameMode, cursorFix: p.cursorFix))
            } else {
                playSession.update(nil)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func perform(on game: Game, _ work: @escaping () async throws -> Void) async {
        busyGames.insert(game.exe)
        defer { busyGames.remove(game.exe) }
        do { try await work() } catch { self.error = error.localizedDescription }
        if let i = games.firstIndex(where: { $0.exe == game.exe }) {
            games[i].status = GameScanner.status(exe: game.exe)
        }
    }
}
