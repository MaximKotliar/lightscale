import CryptoKit
import Foundation

/// A newer version of the app, from GitHub Releases.
struct AppRelease: Sendable, Equatable {
    let version: String
    let notes: String
    let page: URL
    let archive: URL
    let signature: URL
}

/// Updates the app from GitHub Releases: the latest release's `Lightscale-<version>.zip` and its Ed25519 signature
/// (`.zip.sig`, made by scripts/release.sh with the private key that stays on the release Mac). The download is
/// verified before anything is unpacked; then a small script waits for the app to quit, swaps the bundle and
/// reopens it. The app isn't signed with a Developer ID, so the signature is what keeps a tampered download out.
/// Files the app downloads itself carry no quarantine flag, so the new version opens without a Gatekeeper prompt.
enum Updater {
    static let feed = URL(string: ProcessInfo.processInfo.environment["LIGHTSCALE_UPDATE_FEED"]
        ?? "https://api.github.com/repos/MaximKotliar/lightscale/releases/latest")!
    /// Public half of the release signing key (Curve25519/Ed25519, raw, base64).
    static let publicKey = "9mu37oTFmID1TGubnsFrtKu4gjF87065EvKZDRr7Qn0="

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    enum Failure: LocalizedError {
        case notBundled, translocated, notWritable(String), badSignature, badArchive(String)

        var errorDescription: String? {
            switch self {
            case .notBundled: "Only the app bundle can update itself."
            case .translocated: "macOS runs \(AppName.display) from a temporary copy because it wasn't moved out of the folder it was downloaded to. Move it to Applications, open it from there, then update."
            case let .notWritable(folder): "\(AppName.display) can't replace itself in “\(folder)”. Download the new version from GitHub instead."
            case .badSignature: "The download doesn't carry a valid signature, so it wasn't installed."
            case let .badArchive(why): "The download isn't a usable \(AppName.display): \(why)."
            }
        }
    }

    /// The latest release if it's newer than this app and signed; nil if there's none.
    static func newerRelease() async throws -> AppRelease? {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData)   // always the current release
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lightscale/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }   // no release yet
        guard let release = try parse(data), isNewer(release.version, than: currentVersion) else { return nil }
        return release
    }

    /// GitHub's release JSON: tag `v<version>`, the `.zip` and `.zip.sig` assets.
    static func parse(_ data: Data) throws -> AppRelease? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset]; let draft: Bool?; let prerelease: Bool? }
        let r = try JSONDecoder().decode(Release.self, from: data)
        guard r.draft != true, r.prerelease != true,
              let zip = r.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sig = r.assets.first(where: { $0.name == zip.name + ".sig" }) else { return nil }   // unsigned: ignore
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        return AppRelease(version: version, notes: r.body ?? "", page: r.html_url,
                          archive: zip.browser_download_url, signature: sig.browser_download_url)
    }

    /// Numeric comparison, component by component ("0.10" > "0.9", "1.0" == "1").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func isValid(signature: Data, for archive: Data) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: archive)
    }

    /// Downloads, verifies and unpacks `release` next to the running app (same volume, so the swap is a rename).
    /// Returns the unpacked bundle.
    static func prepare(_ release: AppRelease, appURL: URL = Bundle.main.bundleURL) async throws -> URL {
        guard appURL.pathExtension == "app" else { throw Failure.notBundled }
        guard !appURL.path.contains("/AppTranslocation/") else { throw Failure.translocated }
        let folder = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable(folder.path) }

        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        do {
            return try await unpack(release, appURL: appURL, into: staging)
        } catch {
            try? fm.removeItem(at: staging)   // nothing of a failed update stays behind
            throw error
        }
    }

    private static func unpack(_ release: AppRelease, appURL: URL, into staging: URL) async throws -> URL {
        let fm = FileManager.default
        let (archiveFile, _) = try await URLSession.shared.download(from: release.archive)
        let (signature, _) = try await URLSession.shared.data(from: release.signature)
        let archive = staging.appending(path: release.archive.lastPathComponent)
        try fm.moveItem(at: archiveFile, to: archive)
        guard isValid(signature: signature, for: try Data(contentsOf: archive, options: .mappedIfSafe)) else {
            throw Failure.badSignature
        }

        let unpacked = staging.appending(path: "unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard try await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else { throw Failure.badArchive("it doesn't unzip") }
        let newApp = unpacked.appending(path: appURL.lastPathComponent)
        guard let info = NSDictionary(contentsOf: newApp.appending(path: "Contents/Info.plist")) else {
            throw Failure.badArchive("no \(appURL.lastPathComponent) inside")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure.badArchive("another app") }
        guard info["CFBundleShortVersionString"] as? String == release.version else { throw Failure.badArchive("not version \(release.version)") }
        guard try await run("/usr/bin/codesign", ["--verify", "--deep", newApp.path]) else { throw Failure.badArchive("its code signature is broken") }
        return newApp
    }

    /// Starts the swap: once this process has quit, `newApp` replaces `appURL` (the old one is kept until the new
    /// one is in place) and opens. The caller quits the app right after.
    static func installOnQuit(_ newApp: URL, appURL: URL = Bundle.main.bundleURL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.previous"
        if mv "$2" "$2.previous" && mv "$3" "$2"; then rm -rf "$2.previous"; else mv "$2.previous" "$2"; fi
        rm -rf "$4"
        open "$2"
        """
        let staging = newApp.deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), appURL.path, newApp.path, staging.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func run(_ tool: String, _ args: [String]) async throws -> Bool {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
    }
}
