import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GameListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.games) { game in
                GameRow(game: game, isRunning: model.liveStats(for: game) != nil)
                    .tag(game.id)
                    .contextMenu {
                        if game.isCustom {
                            Button("Remove from List") { model.removeFromList(game) }
                                .disabled(game.isInstalled)
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.exe]) }
                    }
            }
        }
        .overlay {
            if model.games.isEmpty && !model.isChecking {
                ContentUnavailableView("No Games", systemImage: "gamecontroller",
                                       description: Text("Steam games in your CrossOver bottles appear here. Add others with Add Game, wherever they are."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { AddGamePanels.run(model: model) } label: { Label("Add Game", systemImage: "plus") }
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan bottles")
                    .disabled(model.isChecking)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

/// Add Game's panels, one after the other: the exe, then (for one outside every bottle) which bottle runs it.
/// AppKit's modal panels, because a SwiftUI dialog opened as the file picker closes may not show.
@MainActor
private enum AddGamePanels {
    static func run(model: AppModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose the game's .exe"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.directoryURL = model.addGameStartFolder
        guard panel.runModal() == .OK, let exe = panel.url else { return }
        model.addGame(exe: exe)
        if let pending = model.pendingGame { askBottle(pending, model: model) }
    }

    private static func askBottle(_ pending: AppModel.PendingGame, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Which bottle runs \(pending.exe.lastPathComponent)?"
        alert.informativeText = "The game is outside your CrossOver bottles. Pick the bottle you run it with: Lightscale sets that bottle up for it."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for bottle in pending.bottles {
            // two bottles can share a name (CrossOver's folder and ~/CXPBottles): show where each is
            let folder = bottle.url.deletingLastPathComponent().path
            popup.addItem(withTitle: "\(bottle.name) — \(folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder)")
        }
        if !pending.bottles.isEmpty {
            alert.accessoryView = popup
            alert.addButton(withTitle: "Add")
        }
        alert.addButton(withTitle: "Choose Bottle Folder…")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let choosesFolder = pending.bottles.isEmpty ? response == 0 : response == 1
        if !pending.bottles.isEmpty && response == 0 {
            model.addPendingGame(in: pending.bottles[popup.indexOfSelectedItem])
        } else if choosesFolder {
            let panel = NSOpenPanel()
            panel.message = "Choose the CrossOver bottle that runs the game"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = Bottle.roots.first
            if panel.runModal() == .OK, let folder = panel.url { model.addPendingGame(bottleFolder: folder) }
            else { model.pendingGame = nil }
        } else {
            model.pendingGame = nil
        }
    }
}

private struct GameRow: View {
    let game: Game
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            GameIcon(game: game)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(isRunning ? .blue : game.status.color).frame(width: 6, height: 6)
                    Text(isRunning ? "Running" : game.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
