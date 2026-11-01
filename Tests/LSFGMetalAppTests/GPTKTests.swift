import Foundation
import Testing
@testable import LSFGMetalApp

/// A fake GPTK folder: D3DMetal's Info.plist with `version`, plus a marker file in wine/.
private func makeGPTK(_ version: String, in root: URL, name: String? = nil) throws -> URL {
    let folder = root.appending(path: name ?? version)
    let resources = folder.appending(path: "external/D3DMetal.framework/Versions/A/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try (["CFBundleShortVersionString": version] as NSDictionary).write(to: resources.appending(path: "Info.plist"))
    let wine = folder.appending(path: "wine/x86_64-windows")
    try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
    try Data(version.utf8).write(to: wine.appending(path: "d3d12.dll"))
    return folder
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lsfg-gptk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func gptkVersionsAreListedNewestFirstWithoutDuplicates() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundled = dir.appending(path: "bundled"), saved = dir.appending(path: "saved")
    _ = try makeGPTK("3.0", in: bundled)
    _ = try makeGPTK("4.0b3", in: bundled)
    _ = try makeGPTK("3.0", in: saved, name: "copy")
    _ = try makeGPTK("2.1", in: saved)
    try FileManager.default.createDirectory(at: bundled.appending(path: "not-gptk"), withIntermediateDirectories: true)

    let versions = GPTK.available(in: [bundled, saved])
    #expect(versions.map(\.version) == ["4.0b3", "3.0", "2.1"])
    #expect(versions.first { $0.version == "3.0" }?.folder.deletingLastPathComponent().lastPathComponent == "bundled")
}

@Test func gptkSwitchReplacesFilesAndSavesAnUnknownVersion() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundled = dir.appending(path: "bundled"), saved = dir.appending(path: "saved")
    let crossOver = try makeGPTK("3.1", in: dir, name: "apple_gptk")   // a version the app doesn't carry
    _ = try makeGPTK("4.0b3", in: bundled)
    let available = GPTK.available(in: [bundled])

    try await GPTK.install(available[0], at: crossOver, available: available, saveTo: saved)
    #expect(GPTK.version(of: crossOver) == "4.0b3")
    #expect(try String(contentsOf: crossOver.appending(path: "wine/x86_64-windows/d3d12.dll"), encoding: .utf8) == "4.0b3")
    // Nothing left over from the swap.
    #expect(try FileManager.default.contentsOfDirectory(atPath: crossOver.path).sorted() == ["external", "wine"])
    // 3.1 was kept and can be switched back to.
    let all = GPTK.available(in: [bundled, saved])
    #expect(all.map(\.version) == ["4.0b3", "3.1"])

    try await GPTK.install(all[1], at: crossOver, available: all, saveTo: saved)
    #expect(GPTK.version(of: crossOver) == "3.1")
}

@Test func gameProfileKeepsItsGPTKChoice() throws {
    let profile = GameProfile(gptk: "3.0")
    let decoded = try JSONDecoder().decode(GameProfile.self, from: try JSONEncoder().encode(profile))
    #expect(decoded.gptk == "3.0")
    // No choice: the key is left out, so the file stays as before.
    let json = String(decoding: try JSONEncoder().encode(GameProfile()), as: UTF8.self)
    #expect(!json.contains("gptk"))
}
