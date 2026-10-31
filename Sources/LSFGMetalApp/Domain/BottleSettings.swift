import Foundation

/// Frame-generation settings for one bottle. The hook reads them from environment variables,
/// which CrossOver sets from the bottle's [EnvironmentVariables]; they apply to every hooked
/// game in the bottle when it next starts.
struct FrameGenSettings: Equatable, Sendable {
    var enabled = true
    var performance = true
    var flowScale = 1.0
    var bufferMs = 8.0

    static let marker = "lsfg-metal settings"

    static func load(_ bottle: Bottle) -> FrameGenSettings {
        var s = FrameGenSettings()
        for line in BottleConf(url: bottle.conf).blockLines(marker) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false).map(String.init) // "KEY" = "VALUE"
            guard parts.count >= 4 else { continue }
            let value = parts[3]
            switch parts[1] {
            case "LSFG_FG": s.enabled = value != "0"
            case "LSFG_PERFORMANCE": s.performance = value != "0"
            case "LSFG_FLOW_SCALE": s.flowScale = Double(value) ?? s.flowScale
            case "LSFG_BUFFER_MS": s.bufferMs = Double(value) ?? s.bufferMs
            default: break
            }
        }
        return s
    }

    func save(to bottle: Bottle) throws {
        let entries = [("LSFG_FG", enabled ? "1" : "0"), ("LSFG_PERFORMANCE", performance ? "1" : "0"),
                       ("LSFG_FLOW_SCALE", String(format: "%.2f", flowScale)), ("LSFG_BUFFER_MS", String(format: "%.0f", bufferMs))]
        try BottleConf(url: bottle.conf).setBlock(Self.marker, section: "EnvironmentVariables",
                                                  lines: entries.map { "\"\($0.0)\" = \"\($0.1)\"" })
    }
}
