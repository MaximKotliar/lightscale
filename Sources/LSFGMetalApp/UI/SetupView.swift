import AppKit
import SwiftUI

struct SetupView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.status.checks) { check in
                    CheckRow(check: check, model: model)
                }
            } header: {
                Text(model.status.isReady ? "Everything's in place" : "\(model.issues) thing\(model.issues == 1 ? "" : "s") to fix")
            } footer: {
                Text("Frame generation uses the shaders from your own Steam copy of Lossless Scaling. They're translated on this Mac and never leave it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .toolbar {
            Button { Task { await model.refresh() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                .disabled(model.isChecking)
        }
        .overlay { if model.status.checks.isEmpty { ProgressView() } }
    }
}

private struct CheckRow: View {
    let check: Check
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let fix = check.fix { FixButton(fix: fix, model: model) }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch check.state {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch check.state {
        case .ok: .green
        case .warning: .orange
        case .missing: .red
        }
    }
}

private struct FixButton: View {
    let fix: Check.Fix
    let model: AppModel
    @State private var copied = false

    var body: some View {
        switch fix {
        case .translateShaders:
            if let progress = model.translateProgress {
                ProgressView(value: progress).frame(width: 120)
            } else {
                Button("Translate") { Task { await model.translateShaders() } }
                    .buttonStyle(.borderedProminent)
            }
        case let .command(command):
            Button(copied ? "Copied" : "Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .help(command)
        case let .open(url):
            Link("Open", destination: url)
        }
    }
}
