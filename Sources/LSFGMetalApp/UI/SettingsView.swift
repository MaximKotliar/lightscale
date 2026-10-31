import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if model.bottles.count > 1 {
                Picker("Bottle", selection: $model.settingsBottle) {
                    ForEach(model.bottles) { Text($0.name).tag(Optional($0)) }
                }
            }
            Section {
                Toggle("Frame generation", isOn: $model.settings.enabled)
                Picker("Mode", selection: $model.settings.performance) {
                    Text("Performance").tag(true)
                    Text("Quality").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!model.settings.enabled)
            } footer: {
                Text("Doubles the frame rate. Performance mode is about twice as fast and looks nearly the same.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledSlider(title: "Motion detail", value: $model.settings.flowScale, range: 0.25...1, step: 0.05,
                              format: { "\(Int(($0 * 100).rounded()))%" })
                LabeledSlider(title: "Pacing buffer", value: $model.settings.bufferMs, range: 0...20, step: 1,
                              format: { "\(Int($0)) ms" })
            } footer: {
                Text("Lower motion detail is faster. A bigger pacing buffer smooths uneven frame times at the cost of a little lag.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.settings.enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .safeAreaInset(edge: .bottom) {
            Text("Applies to every game in this bottle the next time it starts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .onChange(of: model.settingsBottle) { model.loadSettings() }
        .onChange(of: model.settings) { model.saveSettings() }
        .disabled(model.settingsBottle == nil)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}
