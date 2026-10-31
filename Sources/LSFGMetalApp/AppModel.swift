import AppKit
import Foundation
import Observation

/// UI state for the whole app. Work happens in the Domain services; this only sequences it.
@MainActor @Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case setup = "Setup", games = "Games", settings = "Settings", live = "Live"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .setup: "checklist"
            case .games: "gamecontroller"
            case .settings: "slider.horizontal.3"
            case .live: "waveform.path.ecg"
            }
        }
    }

    var section: Section = .setup
    private(set) var status = SystemStatus()
    private(set) var games: [Game] = []
    private(set) var bottles: [Bottle] = []
    private(set) var isChecking = false
    private(set) var translateProgress: Double?
    private(set) var busyGames: Set<URL> = []
    var settingsBottle: Bottle?
    var settings = FrameGenSettings()
    private var savedSettings = FrameGenSettings()   // what's in the bottle right now
    private(set) var live: [LiveSample] = []
    private(set) var liveUpdated: Date?
    var error: String?

    var issues: Int { status.checks.count { $0.state == .missing } }
    var hookedBottles: [Bottle] { bottles.filter(HookInstaller.bottleIsSetUp) }

    func refresh() async {
        isChecking = true
        defer { isChecking = false }
        status = await DependencyChecker.run()
        bottles = Bottle.all()
        let scanned = await GameScanner.scan(bottles: bottles)
        // Keep games the user added by hand.
        let manual = games.filter { g in !scanned.contains { $0.exe == g.exe } }
            .map { g in Game(name: g.name, bottle: g.bottle, exe: g.exe, status: GameScanner.status(exe: g.exe, antiCheat: nil)) }
        games = (scanned + manual).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if settingsBottle == nil || !bottles.contains(settingsBottle!) {
            settingsBottle = hookedBottles.first ?? status.lossless.flatMap { l in bottles.first { $0.url == l.bottle } } ?? bottles.first
        }
        loadSettings()
    }

    func translateShaders() async {
        guard let dll = status.lossless?.dll, translateProgress == nil else { return }
        translateProgress = 0
        defer { translateProgress = nil }
        do {
            try await ShaderTranslator.translate(dll: dll) { value in
                Task { @MainActor in self.translateProgress = value }
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
        guard let bottle = bottles.first(where: { exe.path.hasPrefix($0.url.path + "/") }) else {
            error = "That program isn't inside a CrossOver bottle."
            return
        }
        guard !games.contains(where: { $0.exe == exe }) else { return }
        games.append(GameScanner.game(exe: exe, bottle: bottle))
    }

    func loadSettings() {
        settings = settingsBottle.map(FrameGenSettings.load) ?? FrameGenSettings()
        savedSettings = settings
    }

    /// Writes the bottle's settings, only when the user actually changed something.
    func saveSettings() {
        guard let bottle = settingsBottle, settings != savedSettings else { return }
        do {
            try settings.save(to: bottle)
            savedSettings = settings
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Polls the hook's log while the Live screen is visible.
    func followLive() async {
        while !Task.isCancelled {
            let (samples, modified) = await Task.detached(priority: .utility) { LiveStats.read() }.value
            live = samples
            liveUpdated = modified
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
        if settingsBottle == nil { settingsBottle = game.bottle }
    }
}
