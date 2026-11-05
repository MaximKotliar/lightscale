import Foundation
import LSFGCore

/// A Lossless.dll the user added from disk, for copies of Lossless Scaling bought outside Steam. The app keeps its own
/// copy, which the hook uses before a Steam install: Wine can always read it there, unlike Downloads or a removable
/// drive. It sits in a subfolder because the data folder is on hooked bottles' DLL search path.
enum LosslessFile {
    static var url: URL { HookFiles.root.appending(path: "lossless/Lossless.dll") }

    /// The added copy, if there is one.
    static var installed: URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }

    enum ImportError: LocalizedError {
        case notLossless(String)
        var errorDescription: String? {
            switch self {
            case let .notLossless(name): "\(name) isn't Lossless Scaling's Lossless.dll: it has none of its shaders."
            }
        }
    }

    /// Checks that `source` is Lossless Scaling's DLL (it holds the frame generation shaders), then copies it in.
    static func add(from source: URL) throws {
        let library = try? LSFGShaderLibrary(dll: source)
        guard let library, !library.entries.isEmpty else { throw ImportError.notLossless(source.lastPathComponent) }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appending(path: ".Lossless.dll.new")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        _ = try fm.replaceItemAt(url, withItemAt: temporary)
    }

    static func remove() throws {
        if installed != nil { try FileManager.default.removeItem(at: url) }
    }
}
