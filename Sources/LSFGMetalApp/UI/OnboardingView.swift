import SwiftUI

/// First launch only: checks everything once, then hands over to the main window.
struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("LSFG Metal").font(.largeTitle.weight(.bold))
                Text("Smoother Windows games in CrossOver, using frame generation from your own copy of Lossless Scaling.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
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
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
