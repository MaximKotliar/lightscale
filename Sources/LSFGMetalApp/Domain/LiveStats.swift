import Foundation

/// One second of the hook's own measurements (from ~/Library/Logs/Lightscale.log).
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
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(AppName.folder).log")
    }

    /// What the hook is measuring right now: the game it runs in and its last samples.
    struct Snapshot: Sendable {
        var process: String?
        var samples: [LiveSample] = []
        var modified: Date?

        /// The hook wrote within the last few seconds, i.e. a game is running.
        var isLive: Bool { (modified.map { -$0.timeIntervalSinceNow } ?? .infinity) < 3 && !samples.isEmpty }
    }

    /// The last `count` per-second samples of the most recent game.
    static func read(count: Int = 60) -> Snapshot {
        let url = logURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Snapshot(modified: modified) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let lines = text.split(separator: "\n")
        let samples = lines.compactMap(parse)
        guard let lastPID = samples.last?.pid else { return Snapshot(modified: modified) }
        let process = lines.lazy.compactMap { $0.firstMatch(of: loaded) }.last { Int($0.pid) == lastPID }.map { String($0.name) }
        return Snapshot(process: process, samples: Array(samples.filter { $0.pid == lastPID }.suffix(count)), modified: modified)
    }

    private static var loaded: Regex<(Substring, pid: Substring, name: Substring)> {
        /pid (?<pid>\d+)\] lsfghook loaded in (?<name>\S+)[ ]/
    }
    private static var line: Regex<(Substring, t: Substring, pid: Substring, rest: Substring)> {
        /\[(?<t>[\d.]+) pid (?<pid>\d+)\] per second:(?<rest>.*)/
    }
    private static var shown: Regex<(Substring, fps: Substring, ms: Substring, sd: Substring, drop: Substring)> {
        /on screen (?<fps>\d+) fps, interval (?<ms>[\d.]+) ms ±(?<sd>[\d.]+), max [\d.]+, dropped (?<drop>\d+)/
    }

    /// The game's own frames: it takes one drawable per frame (`layer.nextDrawable`). Our overlay
    /// gets its drawables from the display link, but `drawable.present` counts its presents too,
    /// so that one is only a fallback for logs without the drawable counter.
    static func parse(_ text: Substring) -> LiveSample? {
        guard let m = text.firstMatch(of: line) else { return nil }
        let rest = String(m.rest)
        func count(_ key: String) -> Int {
            guard let r = rest.firstMatch(of: try! Regex("\(key)=(\\d+)")) else { return 0 }
            return Int(r.output[1].substring ?? "") ?? 0
        }
        let s = rest.firstMatch(of: shown)
        return LiveSample(time: Double(m.t) ?? 0, pid: Int(m.pid) ?? 0, realFPS: count("layer.nextDrawable") > 0 ? count("layer.nextDrawable") : count("drawable.present"),
                          generated: count("generated"), shownFPS: s.flatMap { Int($0.fps) },
                          frameTimeMs: s.flatMap { Double($0.ms) }, spreadMs: s.flatMap { Double($0.sd) },
                          dropped: s.flatMap { Int($0.drop) })
    }
}
