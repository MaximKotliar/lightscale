import AppKit
import SwiftUI

struct GameDetailView: View {
    let game: Game
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Header(game: game, model: model)
                SupportRow(game: game)
                GameProgramCard(game: game, model: model)
                if case let .blocked(reason) = game.status {
                    Label(blockedExplanation(reason), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ProfileCard(game: game, model: model)
                    UpscalerCard(game: game, model: model)
                    HUDCard(game: game, model: model)
                    WhilePlayingCard(game: game, model: model)
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
            if model.status.losslessDLL == nil { NeedsLosslessNote(what: "Frame generation") }
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

/// Two independent settings that can stack:
/// - DLSS Replacement: what runs in place of the game's DLSS (D3DMetal's MetalFX, or NSS). Needs a game with DLSS.
/// - Display Scaling: Lossless Scaling's upscalers scale the finished frames (generated ones too) up to the screen. Any game.
private struct UpscalerCard: View {
    let game: Game
    let model: AppModel

    private var profile: Binding<GameProfile> {
        Binding(get: { model.profile(for: game) }, set: { model.setProfile($0, for: game) })
    }

    static let scalers: [(tag: String, name: String)] = [("ls1", "LS1"), ("fsr", "FSR"), ("nis", "NIS"), ("bcas", "BCAS"),
                                                          ("bicubic", "Bicubic"), ("nearest", "Nearest")]
    /// Upscalers that come with Lightscale rather than from Lossless Scaling.
    static let ownScalers: Set<String> = ["nis", "nearest"]

    var body: some View {
        let dlss = game.upscalers.contains(.dlss)
        let fsr = game.upscalers.contains(.fsr)
        let viaFSR = model.fsrPathGames.contains(game.exe)
        let p = profile.wrappedValue
        let ready = NSSFiles.isReady
        Card(title: "Upscaling") {
            if dlss || fsr {
                if !game.bottle.dlssEnabled {
                    Label("DLSS is off in the “\(game.bottle.name)” bottle, so the game can't offer it\(fsr ? " and FSR can't be replaced" : ""). Turn on DLSS in the bottle's settings in CrossOver, then restart the game.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if fsr {
                    SettingRow(title: "Replaces", caption: pathCaption(viaFSR: viaFSR, dlss: dlss)) {
                        if model.busyGames.contains(game.exe) { ProgressView().controlSize(.small) }
                        Picker("Replaces", selection: Binding(get: { viaFSR }, set: { on in Task { await model.setReplacesFSR(on, for: game) } })) {
                            Text(dlss ? "DLSS" : "Off").tag(false)
                            Text("FSR").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(model.busyGames.contains(game.exe))
                    }
                }
                if dlss || viaFSR {
                    SettingRow(title: fsr ? "Replace with" : "DLSS Replacement", caption: replacementCaption(p.upscaler, ready: ready, viaFSR: viaFSR),
                               warn: p.upscaler == "nss" && !ready) {
                        Picker("Replace with", selection: profile.upscaler) {
                            Text("MetalFX").tag("metalfx")
                            Text("NSS").tag("nss")
                        }
                        .labelsHidden()
                    }
                    if p.upscaler == "nss" {
                        SettingRow(title: "NSS quality", caption: "Fast: about ⅔ of Mid's GPU time, as sharp in motion, fine detail in still scenes like MetalFX. High costs about 3× Mid.") {
                            Picker("NSS quality", selection: profile.nssQuality) {
                                if p.nssQuality == "low" { Text("Low").tag("low") }
                                Text("Fast").tag("fast")
                                Text("Mid").tag("mid")
                                Text("High").tag("high")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        NSSTermsNote()
                    }
                }
            } else {
                NoDLSSNote(game: game)
            }
            Divider()
            SettingRow(title: "Display Scaling", caption: scalingCaption(p.scaler)) {
                Picker("Display Scaling", selection: profile.scaler) {
                    Text("Off").tag("off")
                    ForEach(Self.scalers, id: \.tag) { Text($0.name).tag($0.tag) }
                }
                .labelsHidden()
            }
            if model.status.losslessDLL == nil && p.scaler != "off" && !Self.ownScalers.contains(p.scaler) {
                NeedsLosslessNote(what: "This upscaler")   // NIS and Nearest come with Lightscale
            }
            if ["ls1", "fsr", "bcas", "nis"].contains(p.scaler) {
                SliderRow(title: "Sharpness", value: profile.scalerSharpness, range: 0...1, step: 0.25) { "\(Int(($0 * 100).rounded()))%" }
            }
            if p.scaler == "ls1" {
                SettingRow(title: "Performance", caption: "LS1's single-pass variant: about half the GPU time, a little less detail.") {
                    Toggle("Performance", isOn: profile.scalerPerformance).labelsHidden()
                }
            }
        }
    }

    private func pathCaption(viaFSR: Bool, dlss: Bool) -> String {
        if viaFSR {
            return "The game's FSR goes through OptiScaler (GPL-3.0), which Lightscale put in the game's folder. Choose FSR in the game's graphics settings." + (dlss ? " Its DLSS is still replaced too." : "")
        }
        return (dlss ? "Which of the game's upscalers to replace. " : "Replace the game's FSR. ")
            + "FSR: Lightscale adds OptiScaler (GPL-3.0, downloaded from its GitHub page the first time) to the game's folder."
    }

    private func replacementCaption(_ upscaler: String, ready: Bool, viaFSR: Bool) -> String {
        let what = viaFSR ? "the game's FSR" : "the game's DLSS"
        let enable = viaFSR ? "Choose FSR in the game's graphics settings." : "Enable DLSS in the game's graphics settings."
        if upscaler == "nss" {
            if !ready { return "NSS files aren't installed yet: uninstall and install the game again." }
            return "Runs instead of \(what). \(enable) NSS: a sharper, more stable image than MetalFX at about the same GPU cost (Mid)."
        }
        return "Runs instead of \(what). \(enable)"
    }

    private func scalingCaption(_ scaler: String) -> String {
        guard scaler != "off" else { return "Scales the finished image up to your screen's resolution. Works in any game and stacks with the setting above." }
        let what = ["ls1": "Lossless Scaling's own trained upscaler", "fsr": "AMD FSR 1",
                    "bcas": "bicubic with AMD's contrast-adaptive sharpening", "bicubic": "plain bicubic",
                    "nearest": "nearest neighbour (sharp pixels; integer scaling at whole ratios)",
                    "nis": "NVIDIA Image Scaling (edge-aware, with sharpening; less GPU time than FSR)"][scaler] ?? scaler
        let source = Self.ownScalers.contains(scaler) ? "Built into Lightscale: works without Lossless Scaling." : "Uses your Lossless Scaling."
        return "Scales the finished image up to your screen's resolution with \(what). Works in any game and stacks with the setting above. \(source)"
    }
}

/// Lightscale's own HUD, drawn by the hook on the final image of every frame on screen, so the numbers are
/// visible while playing and are never interpolated or scaled.
private struct HUDCard: View {
    let game: Game
    let model: AppModel

    var body: some View {
        Card(title: "Performance HUD") {
            SettingRow(title: "Show in game", caption: "In the game's top-right corner: fps on screen and the game's own, frame pacing, and where an average frame's GPU time goes (game, DLSS replacement, frame generation, display scaling) against its time budget. Averaged over 2 seconds, restarted when a setting changes.") {
                Toggle("Show in game", isOn: Binding(get: { model.profile(for: game).hud }, set: { on in
                    var p = model.profile(for: game)
                    p.hud = on
                    model.setProfile(p, for: game)
                }))
                .labelsHidden()
            }
            if model.profile(for: game).hud {
                SliderRow(title: "Size", value: Binding(get: { model.profile(for: game).hudScale }, set: { scale in
                    var p = model.profile(for: game)
                    p.hudScale = scale
                    model.setProfile(p, for: game)
                }), range: 0.75...2, step: 0.25) { "\(Int(($0 * 100).rounded()))%" }
            }
        }
    }
}

/// What Lightscale does while the game runs, outside the game: macOS Game Mode, and MacGamingFix's cursor fix.
private struct WhilePlayingCard: View {
    let game: Game
    let model: AppModel

    private func binding(_ key: WritableKeyPath<GameProfile, Bool>) -> Binding<Bool> {
        Binding(get: { model.profile(for: game)[keyPath: key] }, set: { on in
            var p = model.profile(for: game)
            p[keyPath: key] = on
            model.setProfile(p, for: game)
        })
    }

    var body: some View {
        Card(title: "While Playing") {
            SettingRow(title: "Game Mode", caption: model.playSession.gameModeAvailable == false
                ? "Needs Xcode's command line tools: run xcode-select --install in Terminal, then reopen Lightscale."
                : "Turns on macOS Game Mode while the game runs (more CPU and GPU time for it, lower Bluetooth latency), and back to automatic when it quits.") {
                Toggle("Game Mode", isOn: binding(\.gameMode)).labelsHidden()
                    .disabled(model.playSession.gameModeAvailable == false)
            }
            SettingRow(title: "Cursor fix", caption: "Stops the Mac's cursor flashing over the game when the hidden one drifts into the Dock, menu bar or a hot corner; menus that show the cursor still do. From MacGamingFix by Evert Junior. Lightscale must stay open.") {
                Toggle("Cursor fix", isOn: binding(\.cursorFix)).labelsHidden()
            }
        }
    }
}

/// The exe the hook goes next to, out of every one in the game's folder that can take it. A game's
/// folder may hold a launcher stub that can't (GTA V's PlayGTAV.exe) next to the real game.
private struct GameProgramCard: View {
    let game: Game
    let model: AppModel

    var body: some View {
        Group {
            if let choices = model.exeChoices[game.id], choices.contains(where: { $0 != game.exe }) {
                let options = choices.contains(game.exe) ? choices : [game.exe] + choices
                Card(title: "Game Program") {
                    SettingRow(title: "Program", caption: game.isInstalled
                        ? "Uninstall to pick another program."
                        : "The program the game runs as. Programs that can't take the hook, like launchers, aren't listed.") {
                        Picker("Program", selection: Binding(get: { game.exe }, set: { model.chooseExe($0, for: game) })) {
                            ForEach(options, id: \.self) { exe in
                                Text(relativePath(exe)).tag(exe)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(game.isInstalled)
                    }
                }
            }
        }
        .task(id: game.id) { await model.loadExeChoices(for: game) }
    }

    private func relativePath(_ exe: URL) -> String {
        let root = game.root.path + "/"
        return exe.path.hasPrefix(root) ? String(exe.path.dropFirst(root.count)) : exe.lastPathComponent
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
/// What the game can use, at a glance: the frame-generation hook, and the upscalers it ships.
private struct SupportRow: View {
    let game: Game

    var body: some View {
        HStack(spacing: 6) {
            switch game.status {
            case .blocked: StatusPill(text: "Frame generation: not supported", color: .orange)
            default: StatusPill(text: "Frame generation", color: .green)
            }
            ForEach(UpscalerTech.allCases, id: \.self) { tech in
                if game.upscalers.contains(tech) { StatusPill(text: tech.label, color: tech == .dlss ? .green : .secondary) }
            }
            if !game.upscalers.contains(.dlss) { StatusPill(text: "No DLSS", color: .secondary) }
        }
        .help("Found in the game's folder. NSS and MetalFX upscaling need the game's own DLSS.")
    }
}

/// The game has no DLSS: say why upscaling isn't available, and what could make it work.
private struct NoDLSSNote: View {
    let game: Game

    var body: some View {
        let others = UpscalerTech.allCases.filter { $0 != .dlss && game.upscalers.contains($0) }.map(\.label)
        VStack(alignment: .leading, spacing: 6) {
            Label("This game doesn't use DLSS, so NSS and MetalFX have nothing to take over.", systemImage: "info.circle")
            if others.isEmpty {
                Text("NSS and MetalFX need a game with DLSS. Use Display Scaling instead: it works in any game.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("It ships \(others.joined(separator: " and ")). A mod such as OptiScaler can route the game's \(others.joined(separator: " or ")) through DLSS, which would make NSS possible here; that route isn't supported yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Frame generation and display scaling run Lossless Scaling's own shaders, read from the user's copy.
private struct NeedsLosslessNote: View {
    let what: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("\(what) needs Lossless Scaling, which isn't installed. These settings do nothing until it is.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Link("Buy on Steam", destination: LosslessScaling.store)
        }
        .font(.callout)
    }
}

/// Arm's license for the NSS weights requires telling users that its acceptable-use terms apply.
struct NSSTermsNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NSS uses Arm's Neural Super Sampling model, licensed under the Arm AI Model Community License. By using NSS you agree to its acceptable-use terms.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                NSSTermsButton(title: "Acceptable Use", file: NSSFiles.acceptableUseFile)
                NSSTermsButton(title: "Arm License", file: NSSFiles.licenseFile)
            }
            .font(.caption)
        }
    }
}

struct NSSTermsButton: View {
    let title: String
    let file: String

    var body: some View {
        if let url = NSSFiles.terms(file) {
            Button(title) { NSWorkspace.shared.open(url) }
                .buttonStyle(.link)
        }
    }
}

/// An ⓘ that shows `text`: as a tooltip on hover, or in a popover on click. Brightens while the pointer is over it.
private struct InfoButton: View {
    let text: String
    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: hovering || shown ? "info.circle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(hovering || shown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(text)
        .accessibilityLabel("More info")
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    var warn = false
    @ViewBuilder let control: Control

    /// The caption stays out of the way behind an ⓘ next to the title (hover to read it); a warning is always shown.
    var body: some View {
        HStack(alignment: warn && caption != nil ? .top : .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                    if let caption, !warn { InfoButton(text: caption) }
                }
                if let caption, warn {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control.frame(width: 280)
        }
    }
}
