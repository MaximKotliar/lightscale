import Foundation
import Testing
@testable import LSFGMetalApp

@Test func bottleConfBlockRemovalRestoresFileExactly() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lsfg-conf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "cxbottle.conf")
    let original = "[Bottle]\n\"Template\" = \"win10_64\"\n\n[EnvironmentVariables]\n\"WINEMSYNC\" = \"1\"\n"
    try original.write(to: url, atomically: true, encoding: .utf8)

    let conf = BottleConf(url: url)
    try conf.setBlock("lsfg-metal", section: "Wine", lines: ["\"LibPath\" = \"x\""])   // new section
    try conf.setBlock("other", section: "EnvironmentVariables", lines: ["\"A\" = \"1\""]) // existing section
    #expect(conf.blockLines("other") == ["\"A\" = \"1\""])
    try conf.removeBlock("lsfg-metal")
    try conf.removeBlock("other")
    #expect(try String(contentsOf: url, encoding: .utf8) == original)
}

@Test func profilesEncodeTheKeysTheHookReads() throws {
    var file = ProfileFile()
    file.games["witcher3.exe"] = GameProfile(enabled: false, multiplier: 4, performance: false, flowScale: 0.5, bufferMs: 12)
    let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(file)) as? [String: Any]
    let game = (json?["games"] as? [String: Any])?["witcher3.exe"] as? [String: Any]
    #expect(game?["enabled"] as? Bool == false)
    #expect(game?["performance"] as? Bool == false)
    #expect(game?["flowScale"] as? Double == 0.5)
    #expect(game?["bufferMs"] as? Double == 12)
    #expect(game?["multiplier"] as? Int == 4)
    #expect(json?["default"] != nil)
}

@Test func profileLevelMapsToEnabledAndMultiplier() {
    var p = GameProfile()
    #expect(p.level == 1)
    p.level = 2
    #expect(p.enabled && p.multiplier == 4)
    p.level = 0
    #expect(!p.enabled && p.level == 0)
    p.level = 1
    #expect(p.enabled && p.multiplier == 2)
}

@Test func olderProfileFilesStillLoad() throws {
    // Written before `multiplier` and `custom` existed.
    let json = #"{"default":{"enabled":true,"performance":true,"flowScale":1,"bufferMs":8},"games":{"a.exe":{"enabled":false}}}"#
    let file = try JSONDecoder().decode(ProfileFile.self, from: Data(json.utf8))
    #expect(file.default.multiplier == 2)
    #expect(file.games["a.exe"]?.enabled == false)
    #expect(file.games["a.exe"]?.bufferMs == 8)
    #expect(file.custom.isEmpty)
}

/// Full install and uninstall through the app's code, against the throwaway test bottle
/// (LSFG_TEST_BOTTLE). Skipped when it isn't set up.
@Test func installAndUninstallRoundTrip() async throws {
    guard let path = ProcessInfo.processInfo.environment["LSFG_TEST_BOTTLE"],
          let crossOver = CrossOverInstall.find(), HookFiles.source != nil else { return }
    let bottle = Bottle(url: URL(fileURLWithPath: path))
    let gameDir = bottle.url.appending(path: "drive_c/game")
    let exe = gameDir.appending(path: "vertest.exe")
    guard FileManager.default.fileExists(atPath: exe.path) else { return }
    let confBefore = try String(contentsOf: bottle.conf, encoding: .utf8)

    var game = GameScanner.game(exe: exe, bottle: bottle)
    #expect(game.status == .blocked("Doesn't load dinput8 or version.dll")) // vertest only imports kernel32
    game.status = .ready(.version)                                            // force the path for the test
    try await HookInstaller.install(game, crossOver: crossOver)
    #expect(HookFiles.isOurProxy(gameDir.appending(path: "version.dll")))
    #expect(HookInstaller.bottleIsSetUp(bottle))
    #expect(GameScanner.status(exe: exe, antiCheat: nil) == .installed(.version))

    game.status = .installed(.version)
    try await HookInstaller.uninstall(game, crossOver: crossOver, lastInBottle: true)
    #expect(!FileManager.default.fileExists(atPath: gameDir.appending(path: "version.dll").path))
    #expect(!HookInstaller.bottleIsSetUp(bottle))
    #expect(try String(contentsOf: bottle.conf, encoding: .utf8) == confBefore)
}
