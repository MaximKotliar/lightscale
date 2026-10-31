import SwiftUI

/// First launch only: checks everything once, then hands over to the main window.
struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        // Centered when it fits; scrolls instead of clipping when the window is short.
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("LSFG Metal").font(.title.weight(.bold))
                Text("Smoother Windows games in CrossOver, using frame generation from your own copy of Lossless Scaling.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            SetupChecklist(model: model).frame(maxWidth: 520)
            HStack {
                Button("Check Again") { Task { await model.refresh() } }
                    .disabled(model.isChecking)
                Button("Continue") { model.hasCompletedSetup = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.status.isReady)
            }
            .controlSize(.large)
        }
    }
}
