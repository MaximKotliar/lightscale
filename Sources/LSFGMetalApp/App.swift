import AppKit
import SwiftUI

@main
struct LSFGMetalApp: App {
    @State private var model: AppModel

    init() {
        // Started from Terminal (swift run) the process isn't a bundled app yet: make it a regular one.
        NSApplication.shared.setActivationPolicy(.regular)
        // `--section games` opens a given screen (handy for screenshots and docs).
        let model = AppModel()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count,
           let section = AppModel.Section.allCases.first(where: { $0.rawValue.lowercased() == args[i + 1].lowercased() }) {
            model.section = section
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("LSFG Metal", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 680, minHeight: 440)
        }
        .defaultSize(width: 760, height: 500)
        .windowResizability(.contentMinSize)
    }
}
