import AppKit
import SwiftUI

/// Rounded tile with a game's initial on a color derived from its name.
struct GameTile: View {
    let name: String
    var size: CGFloat = 28

    private var hue: Double {
        Double(name.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFF } % 360) / 360
    }

    /// First letter of the name, skipping a leading article ("The Witcher 3" -> "W").
    private var initial: String {
        let words = name.split(separator: " ")
        let word = words.count > 1 && ["the", "a", "an"].contains(words[0].lowercased()) ? words[1] : words.first ?? "?"
        return String(word.first(where: \.isLetter) ?? "?").uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                          Color(hue: hue + 0.06, saturation: 0.7, brightness: 0.55)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Grouped section with a title, like a settings card.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

extension Game.Status {
    var label: String {
        switch self {
        case .installed: "On"
        case .ready: "Not installed"
        case let .blocked(reason): reason
        }
    }

    var color: Color {
        switch self {
        case .installed: .green
        case .ready: .secondary
        case .blocked: .orange
        }
    }
}

/// The setup checklist, used by onboarding and by the "fix it" sheet.
struct SetupChecklist: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.status.checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { Divider().padding(.leading, 44) }
                CheckRow(check: check, model: model)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if model.status.checks.isEmpty { ProgressView().padding() } }
    }
}

private struct CheckRow: View {
    let check: Check
    let model: AppModel
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: check.state == .ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(check.state == .ok ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            fix
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var fix: some View {
        switch check.fix {
        case .buildKernels:
            if let progress = model.buildProgress {
                ProgressView(value: progress).frame(width: 90)
            } else {
                Button("Build") { Task { await model.buildKernels() } }.buttonStyle(.borderedProminent)
            }
        case let .command(command):
            Button(copied ? "Copied" : "Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .help("Run in Terminal: \(command)")
        case let .open(url):
            Link("Get It", destination: url).buttonStyle(.bordered)
        case nil:
            EmptyView()
        }
    }
}
