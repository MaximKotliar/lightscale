import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .badge(section == .setup ? model.issues : 0)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch model.section {
            case .setup: SetupView(model: model)
            case .games: GamesView(model: model)
            case .settings: SettingsView(model: model)
            case .live: LiveView(model: model)
            }
        }
        .task { await model.refresh() }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

/// Small colored status capsule used across screens.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
