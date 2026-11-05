import AppKit
import CursorFence
import Foundation
import Observation

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

    /// Called once a second with what the running game wants (nil: none runs).
    func update(_ new: Wanted?) {
        guard new != wanted else { return }
        wanted = new
        syncCursorFix()
        let wantGameMode = new?.gameMode == true
        if wantGameMode != gameModeOn {
            gameModeOn = wantGameMode
            Task { await Self.setGameMode(wantGameMode ? "on" : "auto") }
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

    private static func setGameMode(_ value: String) async {
        _ = try? await Shell.run(xcrun, ["gamepolicyctl", "game-mode", "set", value])
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
