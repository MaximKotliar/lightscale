import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.hasCompletedSetup {
                NavigationSplitView {
                    GameListView(model: model)
                        .navigationSplitViewColumnWidth(230)
                        .toolbar(removing: .sidebarToggle)
                } detail: {
                    Group {
                        if let game = model.selectedGame {
                            GameDetailView(game: game, model: model)
                        } else {
                            ContentUnavailableView("Select a Game", systemImage: "gamecontroller")
                        }
                    }
                    // Takes its own space above the content rather than covering it.
                    .safeAreaInset(edge: .top, spacing: 0) { ProblemBanner(model: model) }
                }
            } else {
                OnboardingView(model: model)
            }
        }
        .task { await model.refresh() }
        .task { await model.followLive() }
        .sheet(isPresented: $model.showingSetup) { SetupSheet(model: model) }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

/// Shown only when a setup check fails after onboarding (e.g. a Lossless Scaling update).
private struct ProblemBanner: View {
    let model: AppModel

    var body: some View {
        if let problem = model.status.problems.first {
            Button { model.showingSetup = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(problem.title): \(problem.detail)").lineLimit(1)
                    Text("Fix…").fontWeight(.semibold).foregroundStyle(.tint)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct SetupSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup").font(.title2.weight(.semibold))
            SetupChecklist(model: model)
            HStack {
                Button("Check Again") { Task { await model.refresh() } }.disabled(model.isChecking)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
