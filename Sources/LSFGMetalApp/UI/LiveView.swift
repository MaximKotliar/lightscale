import Charts
import SwiftUI

struct LiveView: View {
    let model: AppModel

    private var latest: LiveSample? { model.live.last }
    private var isRunning: Bool { (model.liveUpdated.map { -$0.timeIntervalSinceNow } ?? .infinity) < 3 }

    var body: some View {
        Group {
            if let latest, isRunning {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 28) {
                        Stat(title: "Game", value: "\(latest.realFPS)", unit: "fps")
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.title2)
                        Stat(title: "On screen", value: latest.shownFPS.map(String.init) ?? "–", unit: "fps", accent: true)
                        Divider().frame(height: 44)
                        Stat(title: "Frame time", value: latest.frameTimeMs.map { String(format: "%.1f", $0) } ?? "–",
                             unit: latest.spreadMs.map { String(format: "ms ±%.1f", $0) } ?? "ms")
                        Stat(title: "Dropped", value: latest.dropped.map(String.init) ?? "–", unit: "/s")
                    }
                    // Last 60 seconds, newest at the right edge.
                    Chart(model.live) { sample in
                        LineMark(x: .value("Seconds", sample.time - latest.time), y: .value("fps", sample.shownFPS ?? 0))
                            .foregroundStyle(by: .value("Series", "On screen"))
                        LineMark(x: .value("Seconds", sample.time - latest.time), y: .value("fps", sample.realFPS))
                            .foregroundStyle(by: .value("Series", "Game"))
                    }
                    .chartXScale(domain: -60...0)
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(position: .leading) }
                    .chartForegroundStyleScale(["On screen": Color.accentColor, "Game": Color.secondary])
                    .frame(minHeight: 160)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("No game running", systemImage: "waveform.path.ecg",
                                       description: Text("Start a game with frame generation installed. Its frame rates show up here."))
            }
        }
        .navigationTitle("Live")
        .task { await model.followLive() }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    let unit: String
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(accent ? Color.accentColor : .primary)
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
