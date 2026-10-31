import Charts
import SwiftUI

struct GameDetailView: View {
    let game: Game
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(game: game, model: model)
                if case let .blocked(reason) = game.status {
                    Label(blockedExplanation(reason), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    if let live = model.liveStats(for: game) { LiveCard(live: live) }
                    ProfileCard(game: game, model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(game.name)
    }

    private func blockedExplanation(_ reason: String) -> String {
        if reason.hasPrefix("Anti-cheat") { return "This game uses anti-cheat. Changing what it loads could get your account banned, so it's left alone." }
        if reason.hasPrefix("Another mod") { return "\(reason). Remove that mod to use frame generation here." }
        if reason == "32-bit game" { return "Only 64-bit games are supported." }
        return "This game doesn't load a DLL the hook can use. Frame generation isn't available for it yet."
    }
}

private struct Header: View {
    let game: Game
    let model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GameTile(name: game.name, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.title2.weight(.semibold))
                Text("\(game.bottle.name) · \(game.exe.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(game.exe.path)
            }
            Spacer()
            if model.busyGames.contains(game.exe) {
                ProgressView().controlSize(.small)
            } else {
                switch game.status {
                case .installed:
                    Button("Uninstall") { Task { await model.uninstall(game) } }
                case .ready:
                    Button("Install") { Task { await model.install(game) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.status.isReady)
                case .blocked:
                    StatusPill(text: "Unsupported", color: .orange)
                }
            }
        }
    }
}

private struct ProfileCard: View {
    let game: Game
    let model: AppModel

    private var profile: Binding<GameProfile> {
        Binding(get: { model.profile(for: game) }, set: { model.setProfile($0, for: game) })
    }

    var body: some View {
        Card(title: "Frame Generation") {
            Toggle(isOn: profile.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Double the frame rate")
                    Text("Cap the game at half your display's refresh rate for the smoothest result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Divider()
            Group {
                LabeledContent("Mode") {
                    Picker("Mode", selection: profile.performance) {
                        Text("Performance").tag(true)
                        Text("Quality").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                SliderRow(title: "Motion detail", value: profile.flowScale, range: 0.25...1, step: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                SliderRow(title: "Pacing buffer", value: profile.bufferMs, range: 0...20, step: 1) { "\(Int($0)) ms" }
            }
            .disabled(!profile.wrappedValue.enabled)
            HStack {
                Text(game.isInstalled ? "Changes apply the next time the game starts." : "Install to use these settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hasCustomProfile(game) {
                    Button("Reset") { model.resetProfile(for: game) }.controlSize(.small)
                }
            }
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                // Continuous slider (a stepped one draws a row of tick marks); the value snaps to `step`.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                    .frame(width: 170)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct LiveCard: View {
    let live: LiveStats.Snapshot

    var body: some View {
        let latest = live.samples.last
        Card(title: "Now Playing") {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Stat(value: latest.map { "\($0.realFPS)" } ?? "–", unit: "game fps")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Stat(value: latest?.shownFPS.map(String.init) ?? "–", unit: "on screen", accent: true)
                Spacer()
                Stat(value: latest?.frameTimeMs.map { String(format: "%.1f", $0) } ?? "–",
                     unit: latest?.spreadMs.map { String(format: "ms ±%.1f", $0) } ?? "ms")
            }
            if let last = latest {
                Chart(live.samples) { s in
                    LineMark(x: .value("t", s.time - last.time), y: .value("fps", s.shownFPS ?? 0))
                        .foregroundStyle(Color.accentColor)
                    LineMark(x: .value("t", s.time - last.time), y: .value("fps", s.realFPS), series: .value("s", "game"))
                        .foregroundStyle(.secondary)
                }
                .chartXScale(domain: -60...0)
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 90)
            }
        }
    }
}

private struct Stat: View {
    let value: String
    let unit: String
    var accent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent ? Color.accentColor : .primary)
            Text(unit).font(.callout).foregroundStyle(.secondary)
        }
    }
}
