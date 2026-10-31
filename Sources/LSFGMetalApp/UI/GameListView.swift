import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GameListView: View {
    @Bindable var model: AppModel
    @State private var picking = false

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
                                       description: Text("Steam games in your CrossOver bottles appear here."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { picking = true } label: { Label("Add Game", systemImage: "plus") }
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan bottles")
                    .disabled(model.isChecking)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "exe") ?? .data]) { result in
            if case let .success(url) = result { model.addGame(exe: url) }
        }
        .fileDialogDefaultDirectory(model.addGameStartFolder)
        .fileDialogMessage("Choose the game's .exe inside a CrossOver bottle")
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
