import Foundation
import LSFGCore

/// Translates LSFG 3.1's SPIR-V shaders from the user's Lossless.dll into a Metal library:
/// SPIR-V → MSL (spirv-cross) → AIR (metal) → lsfg.metallib, plus groups.txt with each
/// kernel's threadgroup size. Output goes to the cache folder for that DLL; nothing is shared.
enum ShaderTranslator {
    enum Failure: LocalizedError {
        case toolMissing(String), noShaders

        var errorDescription: String? {
            switch self {
            case let .toolMissing(tool): "\(tool) is missing (see Setup)."
            case .noShaders: "No LSFG 3.1 shaders in this Lossless.dll."
            }
        }
    }

    /// True if the cache for `dll` has a Metal library with every LSFG 3.1 kernel.
    static func isTranslated(dll: URL) -> Bool {
        guard let dir = try? LSFGKernels.cacheDirectory(forDLL: dll),
              FileManager.default.fileExists(atPath: dir.appending(path: "lsfg.metallib").path),
              let groups = try? String(contentsOf: dir.appending(path: "groups.txt"), encoding: .utf8) else { return false }
        let ids = Set(groups.split(separator: "\n").compactMap { UInt32($0.split(separator: " ").first ?? "") })
        return LSFG31Shaders.allIDs(fp16: true, performance: false).union(LSFG31Shaders.allIDs(fp16: true, performance: true))
            .isSubset(of: ids)
    }

    static func translate(dll: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let spirvCross = Shell.which("spirv-cross") else { throw Failure.toolMissing("spirv-cross") }
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let shaders = try LSFGShaderLibrary(dll: dll).spirv
        guard !shaders.isEmpty else { throw Failure.noShaders }
        let out = try LSFGKernels.cacheDirectory(forDLL: dll)
        let work = out.appending(path: "work")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let total = Double(shaders.count)
        let done = Counter()
        // Translate in parallel, a few tools at a time.
        let groups: [(UInt32, String)] = try await withThrowingTaskGroup(of: (UInt32, String).self) { group in
            var results: [(UInt32, String)] = []
            var pending = shaders.sorted { $0.key < $1.key }.makeIterator()
            func addNext() -> Bool {
                guard let (id, code) = pending.next() else { return false }
                group.addTask {
                    let size = try translateOne(id: id, spirv: code, in: work, spirvCross: spirvCross, xcrun: xcrun)
                    progress(Double(await done.increment()) / total)
                    return (id, size)
                }
                return true
            }
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount { if !addNext() { break } }
            while let result = try await group.next() {
                results.append(result)
                _ = addNext()
            }
            return results
        }

        // Link into one library, then swap the results in.
        let airs = groups.map { work.appending(path: "\($0.0).air").path }
        try await Shell.check(xcrun, ["-sdk", "macosx", "metallib"] + airs + ["-o", work.appending(path: "lsfg.metallib").path])
        let groupsText = groups.sorted { $0.0 < $1.0 }.map { "\($0.0) \($0.1)" }.joined(separator: "\n") + "\n"
        try groupsText.write(to: work.appending(path: "groups.txt"), atomically: true, encoding: .utf8)
        for name in ["lsfg.metallib", "groups.txt"] {
            let destination = out.appending(path: name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: work.appending(path: name), to: destination)
        }
        try? FileManager.default.removeItem(at: work)
    }

    /// One shader: returns its threadgroup size as "x y z".
    private static func translateOne(id: UInt32, spirv: Data, in work: URL, spirvCross: URL, xcrun: URL) throws -> String {
        let spv = work.appending(path: "\(id).spv"), msl = work.appending(path: "\(id).metal")
        try spirv.write(to: spv)
        try runSync(spirvCross, [spv.path, "--msl", "--msl-version", "30000", "--msl-decoration-binding",
                                 "--rename-entry-point", "main", "lsfg_\(id)", "comp", "--output", msl.path])
        // Shift lsfg-vk's Vulkan binding ranges into Metal's tables: samplers 16+ → 0+, images 32+ → 0+.
        var source = try String(contentsOf: msl, encoding: .utf8)
        source = remap(source, attribute: "sampler", offset: 16)
        source = remap(source, attribute: "texture", offset: 32)
        try source.write(to: msl, atomically: true, encoding: .utf8)
        try runSync(xcrun, ["-sdk", "macosx", "metal", "-std=metal3.0", "-O3", "-c", msl.path,
                            "-o", work.appending(path: "\(id).air").path])
        guard let size = localSize(spirv) else { throw ParseError.malformed("shader \(id) has no LocalSize") }
        return "\(size.0) \(size.1) \(size.2)"
    }

    private static func remap(_ source: String, attribute: String, offset: Int) -> String {
        source.replacing(/\[\[(sampler|texture)\((\d+)\)\]\]/) { match in
            let n = Int(match.output.2) ?? 0
            guard match.output.1 == attribute, n >= offset else { return String(match.output.0) }
            return "[[\(attribute)(\(n - offset))]]"
        }
    }

    /// OpExecutionMode %main LocalSize x y z, read straight from the SPIR-V words.
    static func localSize(_ spirv: Data) -> (UInt32, UInt32, UInt32)? {
        let words = spirv.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        var i = 5
        while i < words.count {
            let count = Int(words[i] >> 16), opcode = words[i] & 0xFFFF
            guard count > 0 else { return nil }
            if opcode == 16, count >= 6, words[i + 2] == 17 { return (words[i + 3], words[i + 4], words[i + 5]) }
            i += count
        }
        return nil
    }

    /// Runs a tool synchronously from inside a task-group child (each child owns one tool run).
    private static func runSync(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShellError.failed(command: tool.lastPathComponent, output: String(decoding: output, as: UTF8.self))
        }
    }
}

private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}
