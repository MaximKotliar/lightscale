import Foundation
import Testing
@testable import LSFGMetalApp

@Test func bottleIsFoundAboveAFileInsideIt() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "lsfg-bottle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let bottle = dir.appending(path: "Bottles/Steam"), game = bottle.appending(path: "drive_c/Games/BeamNG")
    let outside = dir.appending(path: "Games/BeamNG")
    for folder in [game, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data().write(to: bottle.appending(path: "cxbottle.conf"))

    #expect(Bottle.containing(game.appending(path: "BeamNG.drive.exe"))?.name == "Steam")
    #expect(Bottle.containing(outside.appending(path: "BeamNG.drive.exe")) == nil)
    #expect(Bottle(folder: bottle)?.name == "Steam")
    #expect(Bottle(folder: game) == nil)
}

@Test func renamingAGameAddedByHandKeepsItsBottle() throws {
    var file = ProfileFile()
    file.custom = ["/ssd/GTA/PlayGTAV.exe", "/ssd/Other/Other.exe"]
    file.customBottles["/ssd/GTA/PlayGTAV.exe"] = "/bottles/Steam"
    file.renameCustom("/ssd/GTA/PlayGTAV.exe", to: "/ssd/GTA/GTA5_Enhanced.exe")
    #expect(file.custom == ["/ssd/GTA/GTA5_Enhanced.exe", "/ssd/Other/Other.exe"])
    #expect(file.customBottles == ["/ssd/GTA/GTA5_Enhanced.exe": "/bottles/Steam"])

    file.renameCustom("/ssd/Other/Other.exe", to: "/ssd/GTA/GTA5_Enhanced.exe")   // two entries becoming one
    #expect(file.custom == ["/ssd/GTA/GTA5_Enhanced.exe"])

    let decoded = try JSONDecoder().decode(ProfileFile.self, from: JSONEncoder().encode(file))
    #expect(decoded.customBottles == file.customBottles)
}
