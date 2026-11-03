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
