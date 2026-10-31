import Foundation
import LSFGCore
import Testing
@testable import LSFGMetalApp

/// Translates the user's Lossless.dll into a temporary cache and builds every LSFG 3.1 pipeline.
/// Skipped without a Steam install or the tools.
@Test func translatesShadersIntoWorkingPipelines() async throws {
    guard let dll = LosslessLocator.findAll().first?.dll, Shell.which("spirv-cross") != nil else { return }
    let cache = FileManager.default.temporaryDirectory.appending(path: "lsfg-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cache) }
    setenv("LSFG_CACHE", cache.path, 1)
    defer { unsetenv("LSFG_CACHE") }

    try await ShaderTranslator.translate(dll: dll) { _ in }
    #expect(ShaderTranslator.isTranslated(dll: dll))
    let ids = LSFG31Shaders.allIDs(fp16: true, performance: false).union(LSFG31Shaders.allIDs(fp16: true, performance: true))
    let kernels = try LSFGKernels(cacheDirectory: try LSFGKernels.cacheDirectory(forDLL: dll), ids: ids)
    #expect(kernels.kernels.count == ids.count)
}
