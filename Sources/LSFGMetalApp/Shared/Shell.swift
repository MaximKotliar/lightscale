import Foundation
import Synchronization

/// Output of a finished command-line tool.
struct ShellResult: Sendable {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

enum ShellError: LocalizedError {
    case failed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(command, output):
            let tail = output.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "\(command) failed\(tail.isEmpty ? "" : ":\n\(tail)")"
        }
    }
}

enum Shell {
    /// Runs `executable` and collects stdout and stderr together.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    currentDirectory: URL? = nil) async throws -> ShellResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // Drain the pipe while the tool runs, so a chatty tool can't fill it and stall.
        let collected = Mutex(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.withLock { $0.append(chunk) } }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let data = collected.withLock { $0 + rest }
                continuation.resume(returning: ShellResult(status: finished.terminationStatus,
                                                           output: String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Like `run`, but throws with the tool's output when it exits non-zero.
    @discardableResult
    static func check(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> String {
        let result = try await run(executable, arguments, environment: environment)
        guard result.succeeded else {
            throw ShellError.failed(command: executable.lastPathComponent, output: result.output)
        }
        return result.output
    }

    /// Finds a command-line tool in the usual install locations. GUI apps don't get the
    /// user's shell PATH, so Homebrew's folders are listed explicitly.
    static func which(_ name: String) -> URL? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.lazy.map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
