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
                    UpscalerCard(game: game, model: model)
                    if model.status.crossOver != nil { GPTKCard(game: game, model: model) }
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
            GameIcon(game: game, size: 56)
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
            MultiplierRow(level: profile.level)
            Divider()
            Group {
                SettingRow(title: "Mode") {
                    Picker("Mode", selection: profile.performance) {
                        Text("Performance").tag(true)
                        Text("Quality").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SliderRow(title: "Motion detail", value: profile.flowScale, range: 0.25...1, step: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                SliderRow(title: "Pacing buffer", value: profile.bufferMs, range: 0...20, step: 1) { "\(Int($0)) ms" }
            }
            .disabled(!profile.wrappedValue.enabled)
            HStack {
                Text(game.isInstalled ? "Changes apply right away, even while the game is running." : "Install to use these settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hasCustomProfile(game) {
                    Button("Reset") { model.resetProfile(for: game) }.controlSize(.small)
                }
            }
        }
    }
}

/// What upscales the game's DLSS: MetalFX (what D3DMetal does) or Arm Neural Super Sampling.
private struct UpscalerCard: View {
    let game: Game
    let model: AppModel

    private var profile: Binding<GameProfile> {
        Binding(get: { model.profile(for: game) }, set: { model.setProfile($0, for: game) })
    }

    var body: some View {
        let nss = profile.wrappedValue.upscaler == "nss"
        let ready = NSSFiles.isReady
        Card(title: "Upscaling") {
            SettingRow(title: "Upscaler", caption: caption(nss: nss, ready: ready), warn: nss && !ready) {
                Picker("Upscaler", selection: profile.upscaler) {
                    Text("MetalFX").tag("metalfx")
                    Text("NSS").tag("nss")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingRow(title: "NSS quality", caption: "Mid is the best trade. High costs about 3× as much.") {
                Picker("NSS quality", selection: profile.nssQuality) {
                    Text("Low").tag("low")
                    Text("Mid").tag("mid")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!nss)
        }
    }

    private func caption(nss: Bool, ready: Bool) -> String {
        if !nss { return "Pick DLSS in the game. D3DMetal upscales it with MetalFX." }
        if !ready { return "NSS files aren't installed (\(NSSFiles.directory.path))." }
        return "Pick DLSS in the game; NSS replaces MetalFX. Sharper, about 1.5–2.5 ms more GPU time per frame."
    }
}

/// Which GPTK the game should run with. CrossOver has one GPTK for all games, so a choice that
/// differs from the installed one offers to switch CrossOver over.
private struct GPTKCard: View {
    let game: Game
    let model: AppModel

    private var preference: Binding<String?> {
        Binding(get: { model.profile(for: game).gptk }, set: { value in
            var profile = model.profile(for: game)
            profile.gptk = value
            model.setProfile(profile, for: game)
        })
    }

    var body: some View {
        let installed = model.installedGPTK
        let wanted = preference.wrappedValue
        let target = wanted.flatMap { w in model.gptkVersions.first { $0.version == w } }
        let mismatch = target != nil && wanted != installed

        Card(title: "Game Porting Toolkit") {
            SettingRow(title: "Version", caption: caption(installed: installed, wanted: wanted, found: target != nil), warn: mismatch) {
                Picker("Version", selection: preference) {
                    Text("Any").tag(String?.none)
                    ForEach(model.gptkVersions) { v in
                        Text(v.version == installed ? "\(v.name) (installed)" : v.name).tag(Optional(v.version))
                    }
                }
                .labelsHidden()
                .disabled(model.gptkVersions.isEmpty)
            }
            if mismatch, let target {
                HStack {
                    Text("This changes it for every game in CrossOver. Quit Steam first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isSwitchingGPTK {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Switch to \(target.name)") { Task { await model.switchGPTK(to: target) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func caption(installed: String?, wanted: String?, found: Bool) -> String {
        guard let installed else { return "CrossOver's GPTK files weren't found." }
        if model.gptkVersions.isEmpty { return "CrossOver has GPTK \(installed). This build of the app has no other versions." }
        if let wanted, !found { return "GPTK \(wanted) isn't in this app anymore. CrossOver has GPTK \(installed)." }
        if let wanted, wanted != installed { return "CrossOver has GPTK \(installed). Switch before you play this game." }
        return "CrossOver has GPTK \(installed)."
    }
}

/// Off / 2× / 4× as one three-stop slider.
private struct MultiplierRow: View {
    @Binding var level: Int
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private static let names = ["Off", "2×", "4×"]

    private var hint: String {
        switch level {
        case 0: "The game runs as usual."
        case 1: "Cap the game at half your display's refresh rate for the smoothest result."
        default: lowPower
            ? "Low Power Mode limits the display to 60 Hz, so you'll see 2×. Turn it off for 4×."
            : "Needs a 120 Hz display. Cap the game at a quarter of the refresh rate (30 fps)."
        }
    }

    var body: some View {
        SettingRow(title: "Frame rate", caption: hint, warn: level == 2 && lowPower) {
            HStack(spacing: 10) {
                // Continuous track (matches the other sliders) that snaps to Off / 2× / 4×.
                Slider(value: Binding(get: { Double(level) }, set: { level = Int($0.rounded()) }), in: 0...2)
                Text(Self.names[level]).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
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
        SettingRow(title: title) {
            HStack(spacing: 10) {
                // Continuous slider (a stepped one draws a row of tick marks); the value snaps to `step`.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// One settings line: title (and optional caption) on the left, the control in a fixed right column,
/// so every control in the card lines up.
private struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    var warn = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: caption == nil ? .center : .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control.frame(width: 280)
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
