import AppKit
import CursorFence
import Foundation
import Observation
import os

/// What Lightscale does for a game while it runs, besides the hook: macOS Game Mode on, and the cursor fix
/// (MacGamingFix's) while the game is the app in front. The hook's log says which game runs and its process.
@MainActor @Observable
final class PlaySession {
    /// What the running game wants, or nil when no hooked game runs.
    struct Wanted: Equatable {
        var pid: pid_t
        var gameMode: Bool
        var cursorFix: Bool
    }

    @ObservationIgnored private let fence = CursorFence()
    @ObservationIgnored private var wanted: Wanted?
    @ObservationIgnored private var gameModeOn = false
    /// gamepolicyctl ships with Xcode's command line tools; nil until checked.
    private(set) var gameModeAvailable: Bool?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCursorFix() }
        })
        // Game Mode back to automatic when Lightscale quits (synchronously: the process is on its way out).
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fence.deactivate()
                if self?.gameModeOn == true { Self.setGameModeNow("auto") }
            }
        })
        Task { gameModeAvailable = await Self.gamePolicyAvailable() }
    }

    @ObservationIgnored private var goneSince: Date?
    @ObservationIgnored private var lastGameModeOn = Date.distantPast
    @ObservationIgnored private var commands: Task<Void, Never>?
    private static let log = Logger(subsystem: "dev.lightscale.app", category: "play")

    /// Called once a second with what the running game wants (nil: none runs). A game that seems gone for a moment
    /// (the log between writes, the game list reloading) still counts for 5 seconds, so nothing flickers off.
    func update(_ new: Wanted?) {
        if new == nil, wanted != nil {
            let since = goneSince ?? Date()
            goneSince = since
            if Date().timeIntervalSince(since) < 5 { return }
        }
        goneSince = nil
        if new != wanted {
            Self.log.info("game \(new.map { "pid \($0.pid), game mode \($0.gameMode), cursor fix \($0.cursorFix)" } ?? "gone", privacy: .public)")
            wanted = new
            syncCursorFix()
        }
        let wantGameMode = new?.gameMode == true
        // While the game runs, say "on" again now and then: something else (another app, a system change) may have
        // put the policy back to automatic.
        if wantGameMode != gameModeOn || (wantGameMode && Date().timeIntervalSince(lastGameModeOn) > 15) {
            gameModeOn = wantGameMode
            if wantGameMode { lastGameModeOn = Date() }
            send(wantGameMode ? "on" : "auto")
        }
    }

    /// Game Mode commands run one after another, in order.
    private func send(_ value: String) {
        let previous = commands
        commands = Task {
            await previous?.value
            let ok = await Self.setGameMode(value)
            Self.log.info("game mode \(value, privacy: .public): \(ok ? "done" : "failed", privacy: .public)")
        }
    }

    /// The cursor fix runs only while the game is in front, and follows its process.
    private func syncCursorFix() {
        guard let wanted, wanted.cursorFix, NSWorkspace.shared.frontmostApplication?.processIdentifier == wanted.pid else {
            if fence.isActive { fence.deactivate() }
            return
        }
        if !fence.isActive { fence.activate() }
        fence.setTrackedGamePID(wanted.pid)
    }

    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    private static func gamePolicyAvailable() async -> Bool {
        (try? await Shell.run(xcrun, ["-f", "gamepolicyctl"]))?.status == 0
    }

    private static func setGameMode(_ value: String) async -> Bool {
        (try? await Shell.run(xcrun, ["gamepolicyctl", "game-mode", "set", value]))?.status == 0
    }

    private static func setGameModeNow(_ value: String) {
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["gamepolicyctl", "game-mode", "set", value]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
