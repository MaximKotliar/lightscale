import AppKit
import SwiftUI

@main
struct LSFGMetalApp: App {
    @State private var model: AppModel

    init() {
        // Started from Terminal (swift run) the process isn't a bundled app yet: make it a regular one.
        NSApplication.shared.setActivationPolicy(.regular)
        HookFiles.migrateLegacyFolder()   // before anything reads profiles.json
        let model = AppModel()
        // `--onboarding` shows first-launch setup again (handy for screenshots and docs).
        if CommandLine.arguments.contains("--onboarding") { model.hasCompletedSetup = false }
        // `--install-update`: check, and install a newer version straight away (scripts and testing).
        if CommandLine.arguments.contains("--install-update") {
            Task { @MainActor in
                await model.checkForAppUpdate(userInitiated: true)
                await model.installAppUpdate()
            }
        }
        // Follows the hook's log for as long as the app runs, window or not: the HUD numbers, and Game Mode and the
        // cursor fix while a game runs.
        Task { @MainActor in await model.followLive() }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        // One fixed-size window: no fullscreen, no zoom, nothing to stretch.
        Window(AppName.display, id: "main") {
            ContentView(model: model)
                .frame(width: 860, height: 560)
                .background(FixedWindow())
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.checkForAppUpdate(userInitiated: true) } }
            }
            CommandGroup(after: .appSettings) {
                Button("Check Setup…") { model.showingSetup = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                // Arm's license for the NSS weights: users must be able to see its terms
                Button("NSS Acceptable Use Terms") { if let u = NSSFiles.terms(NSSFiles.acceptableUseFile) { NSWorkspace.shared.open(u) } }
                Button("Arm AI Model Community License") { if let u = NSSFiles.terms(NSSFiles.licenseFile) { NSWorkspace.shared.open(u) } }
            }
        }
    }
}
