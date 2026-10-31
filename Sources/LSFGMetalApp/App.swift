import AppKit
import SwiftUI

@main
struct LSFGMetalApp: App {
    @State private var model: AppModel

    init() {
        // Started from Terminal (swift run) the process isn't a bundled app yet: make it a regular one.
        NSApplication.shared.setActivationPolicy(.regular)
        let model = AppModel()
        // `--onboarding` shows first-launch setup again (handy for screenshots and docs).
        if CommandLine.arguments.contains("--onboarding") { model.hasCompletedSetup = false }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        // One fixed-size window: no fullscreen, no zoom, nothing to stretch.
        Window("LSFG Metal", id: "main") {
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
        }
    }
}
