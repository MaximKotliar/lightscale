import CryptoKit
import Foundation
import Testing
@testable import LSFGMetalApp

@Test func versionsCompareNumerically() {
    #expect(Updater.isNewer("0.3", than: "0.2"))
    #expect(Updater.isNewer("0.10", than: "0.9"))
    #expect(Updater.isNewer("1.0.1", than: "1.0"))
    #expect(!Updater.isNewer("1.0", than: "1"))
    #expect(!Updater.isNewer("0.2", than: "0.3"))
}

@Test func releaseNeedsASignedZip() throws {
    func json(_ assets: [String], prerelease: Bool = false) -> Data {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }.joined(separator: ",")
        return Data(#"{"tag_name":"v0.3","body":"Notes","html_url":"https://example.com/r","prerelease":\#(prerelease),"assets":[\#(list)]}"#.utf8)
    }
    let r = try #require(try Updater.parse(json(["Lightscale-0.3.zip", "Lightscale-0.3.zip.sig"])))
    #expect(r.version == "0.3" && r.archive.lastPathComponent == "Lightscale-0.3.zip" && r.signature.lastPathComponent == "Lightscale-0.3.zip.sig")
    #expect(try Updater.parse(json(["Lightscale-0.3.zip"])) == nil)                                   // unsigned
    #expect(try Updater.parse(json(["Lightscale-0.3.zip", "Lightscale-0.3.zip.sig"], prerelease: true)) == nil)
}

@Test func signatureMustMatchTheShippedKey() throws {
    let data = Data("update".utf8)
    let stranger = Curve25519.Signing.PrivateKey()
    #expect(!Updater.isValid(signature: try stranger.signature(for: data), for: data))   // signed with another key
    #expect(!Updater.isValid(signature: Data(count: 64), for: data))
    #expect(Data(base64Encoded: Updater.publicKey)?.count == 32)
}

@Test func settingsMoveFromEarlierBundleIDs() throws {
    let ids = (0..<3).map { _ in "test.lightscale.\(UUID().uuidString)" }   // newest first, like AppName.bundleIDs
    defer { ids.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
    let current = try #require(UserDefaults(suiteName: ids[0]))
    let previous = try #require(UserDefaults(suiteName: ids[1]))
    let oldest = try #require(UserDefaults(suiteName: ids[2]))
    previous.set(["/Volumes/Games/Bottles"], forKey: "bottleFolders")
    oldest.set(true, forKey: "setupComplete")
    oldest.set(["/old"], forKey: "bottleFolders")

    AppName.migrateSettings(to: current, current: ids[0], from: ids)
    #expect(current.bool(forKey: "setupComplete"))
    #expect(current.stringArray(forKey: "bottleFolders") == ["/Volumes/Games/Bottles"])   // the newer ID wins
    current.set(false, forKey: "setupComplete")
    AppName.migrateSettings(to: current, current: ids[0], from: ids)
    #expect(!current.bool(forKey: "setupComplete"))                                       // its own settings stay
}
