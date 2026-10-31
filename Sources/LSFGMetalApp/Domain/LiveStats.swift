import Foundation

/// One second of the hook's own measurements (from ~/Library/Logs/lsfg-metal.log).
struct LiveSample: Sendable, Identifiable {
    let time: Double          // hook clock (seconds)
    let pid: Int
    let realFPS: Int
    let generated: Int
    let shownFPS: Int?
    let frameTimeMs: Double?
    let spreadMs: Double?
    let dropped: Int?

    var id: Double { time }
}

enum LiveStats {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/lsfg-metal.log")
    }

    /// The last `count` per-second samples, and when the log was last written.
    static func read(count: Int = 60) -> (samples: [LiveSample], modified: Date?) {
        let url = logURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], modified) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let samples = text.split(separator: "\n").compactMap(parse)
        guard let lastPID = samples.last?.pid else { return ([], modified) }
        return (Array(samples.filter { $0.pid == lastPID }.suffix(count)), modified)
    }

    private static var line: Regex<(Substring, t: Substring, pid: Substring, rest: Substring)> {
        /\[(?<t>[\d.]+) pid (?<pid>\d+)\] per second:(?<rest>.*)/
    }
    private static var shown: Regex<(Substring, fps: Substring, ms: Substring, sd: Substring, drop: Substring)> {
        /on screen (?<fps>\d+) fps, interval (?<ms>[\d.]+) ms ±(?<sd>[\d.]+), max [\d.]+, dropped (?<drop>\d+)/
    }

    private static func parse(_ text: Substring) -> LiveSample? {
        guard let m = text.firstMatch(of: line) else { return nil }
        let rest = String(m.rest)
        func count(_ key: String) -> Int {
            guard let r = rest.firstMatch(of: try! Regex("\(key)=(\\d+)")) else { return 0 }
            return Int(r.output[1].substring ?? "") ?? 0
        }
        let s = rest.firstMatch(of: shown)
        return LiveSample(time: Double(m.t) ?? 0, pid: Int(m.pid) ?? 0, realFPS: count("drawable.present"),
                          generated: count("generated"), shownFPS: s.flatMap { Int($0.fps) },
                          frameTimeMs: s.flatMap { Double($0.ms) }, spreadMs: s.flatMap { Double($0.sd) },
                          dropped: s.flatMap { Int($0.drop) })
    }
}
