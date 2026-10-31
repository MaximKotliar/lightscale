import SwiftUI
import UniformTypeIdentifiers

struct GamesView: View {
    let model: AppModel
    @State private var picking = false

    var body: some View {
        Group {
            if model.games.isEmpty {
                ContentUnavailableView("No games found", systemImage: "gamecontroller",
                                       description: Text("Steam games in your CrossOver bottles show up here. Use Add Game for others."))
            } else {
                List {
                    ForEach(model.bottles.filter { b in model.games.contains { $0.bottle == b } }) { bottle in
                        Section(bottle.name) {
                            ForEach(model.games.filter { $0.bottle == bottle }) { game in
                                GameRow(game: game, model: model)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Games")
        .toolbar {
            Button { picking = true } label: { Label("Add Game", systemImage: "plus") }
            Button { Task { await model.refresh() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.isChecking)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.exe]) { result in
            if case let .success(url) = result { model.addGame(exe: url) }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.status.isReady && !model.status.checks.isEmpty {
                Label("Finish Setup before installing.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }
}

private struct GameRow: View {
    let game: Game
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.body.weight(.medium))
                Text(game.exe.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            pill
            action.frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help(game.exe.path)
    }

    @ViewBuilder private var pill: some View {
        switch game.status {
        case let .installed(proxy): StatusPill(text: "On · \(proxy.rawValue)", color: .green)
        case .ready: StatusPill(text: "Ready", color: .blue)
        case let .blocked(reason): StatusPill(text: reason, color: .secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if model.busyGames.contains(game.exe) {
            ProgressView().controlSize(.small)
        } else {
            switch game.status {
            case .installed: Button("Remove") { Task { await model.uninstall(game) } }
            case .ready:
                Button("Install") { Task { await model.install(game) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.status.isReady)
            case .blocked: EmptyView()
            }
        }
    }
}

private extension UTType {
    static let exe = UTType(filenameExtension: "exe") ?? .data
}
