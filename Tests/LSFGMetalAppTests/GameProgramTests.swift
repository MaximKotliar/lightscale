import Foundation
import Testing
@testable import LSFGMetalApp

/// A minimal 64-bit PE that imports `dlls`, padded to `size` bytes (the scan skips exes under 100 KB).
private func writePE(_ url: URL, imports dlls: [String], size: Int = 200_000) throws {
    var d = Data(count: max(size, 0x400))
    func put32(_ v: UInt32, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 4, with: $0) } }
    func put16(_ v: UInt16, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 2, with: $0) } }
    put16(0x5A4D, 0); put32(0x40, 0x3C)                 // MZ, e_lfanew
    put32(0x0000_4550, 0x40); put16(0x8664, 0x44)       // PE, x64
    put16(1, 0x46); put16(240, 0x54); put16(0x20B, 0x58) // 1 section, PE32+ optional header
    put32(dlls.isEmpty ? 0 : 0x1000, 0x58 + 112 + 8)     // import directory RVA
    let section = 0x58 + 240                             // .idata: RVA 0x1000 at file offset 0x200
    put32(0x200, section + 8); put32(0x1000, section + 12); put32(0x200, section + 16); put32(0x200, section + 20)
    var name = 0x200 + 20 * (dlls.count + 1)
    for (i, dll) in dlls.enumerated() {
        put32(UInt32(name - 0x200 + 0x1000), 0x200 + 20 * i + 12)
        d.replaceSubrange(name..<name + dll.utf8.count, with: Data(dll.utf8))
        name += dll.utf8.count + 1
    }
    try d.write(to: url)
}

private func tempFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lsfg-exe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The path below the temp folder (the scan's walker reports /private/var where the test wrote /var).
private func tail(_ url: URL?) -> String? { url.map { $0.path.components(separatedBy: "/lsfg-exe-").last ?? $0.path } }

@Test func launcherPickedByHandIsSwappedForTheGame() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let stub = dir.appending(path: "PlayGTAV.exe"), game = dir.appending(path: "GTA5_Enhanced.exe")
    try writePE(stub, imports: ["kernel32.dll"], size: 300_000)
    try writePE(game, imports: ["kernel32.dll", "version.dll"])
    try writePE(dir.appending(path: "Tool.exe"), imports: ["kernel32.dll"], size: 900_000)

    #expect(GameScanner.status(exe: stub) == .blocked(GameScanner.noProxyReason))
    #expect(GameScanner.gameExe(forPicked: stub) == game)
    #expect(GameScanner.gameExe(forPicked: game) == game)   // a pick that works is kept
}

@Test func scanPrefersAnExeThatCanTakeTheHook() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bottle = Bottle(url: dir)
    let root = dir.appending(path: "Grand Theft Auto V Enhanced")
    let nested = root.appending(path: "bin/x64")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let big = root.appending(path: "Big.exe"), game = nested.appending(path: "Game.exe"), other = root.appending(path: "Other.exe")
    try writePE(big, imports: ["kernel32.dll"], size: 900_000)
    try writePE(game, imports: ["dinput8.dll"], size: 500_000)
    try writePE(other, imports: ["version.dll"], size: 200_000)

    #expect(tail(GameScanner.game(in: root, bottle: bottle)?.exe) == tail(game))                  // largest that can
    #expect(tail(GameScanner.game(in: root, bottle: bottle, chosen: other)?.exe) == tail(other))  // the user's choice wins
    #expect(GameScanner.game(in: root, bottle: bottle)?.root == root)
    #expect(GameScanner.hookableExes(in: root) == [game, other])
}

@Test func profileFileKeepsChosenExes() throws {
    var file = ProfileFile()
    file.exes["/games/GTA"] = "/games/GTA/GTA5_Enhanced.exe"
    let decoded = try JSONDecoder().decode(ProfileFile.self, from: JSONEncoder().encode(file))
    #expect(decoded.exes == file.exes)
    #expect(try JSONDecoder().decode(ProfileFile.self, from: Data("{}".utf8)).exes.isEmpty)
}

@Test func winmmIsUsedOnlyWhenTheOthersAreMissing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let unreal = dir.appending(path: "REANIMAL.exe"), both = dir.appending(path: "Both.exe")
    try writePE(unreal, imports: ["dxgi.dll", "WINMM.dll", "KERNEL32.dll"])
    try writePE(both, imports: ["winmm.dll", "version.dll"])
    #expect(GameScanner.status(exe: unreal) == .ready(.winmm))
    #expect(GameScanner.status(exe: both) == .ready(.version))
}

@Test func compatibilityReportNamesOnlyPathsInsideTheGame() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = dir.appending(path: "Game"), bin = root.appending(path: "Binaries/Win64")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appending(path: "Engine/Binaries"), withIntermediateDirectories: true)
    let exe = bin.appending(path: "Game.exe")
    try writePE(exe, imports: ["dxgi.dll", "helper.dll", "KERNEL32.dll", "api-ms-win-crt-heap-l1-1-0.dll"])
    try writePE(bin.appending(path: "helper.dll"), imports: ["winmm.dll"])
    try writePE(root.appending(path: "Launcher.exe"), imports: ["kernel32.dll"])
    var game = GameScanner.game(exe: exe, bottle: Bottle(url: dir))
    game = Game(name: "Game", bottle: game.bottle, exe: exe, status: game.status, isCustom: true, root: root)

    let report = GameReport.text(for: game, crossOver: "27.0")
    #expect(game.status == .ready(.winmm))                       // through helper.dll
    #expect(report.contains("`Binaries/Win64/Game.exe`"))
    #expect(report.contains("`dxgi.dll` (possible proxy)"))
    #expect(report.contains("`helper.dll` (in the game's folder)"))
    #expect(report.contains("`winmm.dll` **proxy the hook can use**"))
    #expect(report.contains("Unreal Engine"))
    #expect(report.contains("`Launcher.exe`"))
    #expect(!report.contains("api-ms-win"))
    #expect(!report.contains(dir.path))                          // no folders outside the game's
    if let path = ProcessInfo.processInfo.environment["LIGHTSCALE_REPORT_EXE"], let rootPath = ProcessInfo.processInfo.environment["LIGHTSCALE_REPORT_ROOT"] {
        let exe = URL(fileURLWithPath: path)
        let real = Game(name: "Sample", bottle: Bottle(url: dir), exe: exe, status: GameScanner.status(exe: exe),
                        root: URL(fileURLWithPath: rootPath))
        print(GameReport.text(for: real, crossOver: "27.0"))
    }
}
