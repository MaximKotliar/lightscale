import Foundation
import LSFGCore
import Metal

/// One line of the setup checklist.
struct Check: Identifiable, Sendable {
    /// optional: not there, and the app works without it (Lossless Scaling: frame generation and display scaling).
    enum State: Sendable { case ok, missing, optional }
    enum Fix: Sendable, Equatable {
        case command(String)
        case open(URL)
        /// Add Lossless.dll from disk (and a link to buy it, when there's no copy at all).
        case addLossless(store: URL?)
        /// Stop using the Lossless.dll added from disk.
        case removeLossless
    }

    let id: String
    let title: String
    let detail: String
    let state: State
    var fix: Fix?
}

/// What the app needs to know about this Mac.
struct SystemStatus: Sendable {
    var crossOver: CrossOverInstall?
    var lossless: LosslessInstall?
    /// The Lossless.dll the hook uses: one added from disk, else the Steam install's.
    var losslessDLL: URL?
    var checks: [Check] = []

    var problems: [Check] { checks.filter { $0.state == .missing } }
    /// Installing needs only these; without Lossless Scaling the hook still runs NSS/MetalFX and the HUD.
    static let required: Set<String> = ["gpu", "crossover", "hook"]
    var isReady: Bool { !checks.isEmpty && !problems.contains { Self.required.contains($0.id) } }
}

enum LosslessScaling {
    static let store = URL(string: "https://store.steampowered.com/app/993090/")!
}

enum DependencyChecker {
    /// Every LSFG 3.1 kernel the hook may use (fp16, both modes).
    static let kernelIDs = LSFG31Shaders.allIDs(fp16: true, performance: false)
        .union(LSFG31Shaders.allIDs(fp16: true, performance: true))

    static func run() async -> SystemStatus {
        var status = SystemStatus()
        var checks: [Check] = []

        let device = MTLCreateSystemDefaultDevice()
        checks.append(Check(id: "gpu", title: "Apple silicon", detail: device?.name ?? "No Metal GPU found",
                            state: device?.supportsFamily(.apple7) == true ? .ok : .missing))

        status.crossOver = CrossOverInstall.find()
        checks.append(Check(id: "crossover", title: "CrossOver",
                            detail: status.crossOver.map { "Version \($0.version)" } ?? "Install CrossOver to run Windows games",
                            state: status.crossOver == nil ? .missing : .ok,
                            fix: status.crossOver == nil ? .open(URL(string: "https://www.codeweavers.com/crossover")!) : nil))

        // LIGHTSCALE_HIDE_LOSSLESS=1: act as if it isn't installed (to try the app the way users without it see it)
        let hideLossless = ProcessInfo.processInfo.environment["LIGHTSCALE_HIDE_LOSSLESS"] == "1"
        status.lossless = hideLossless ? nil
            : LosslessLocator.findAll(roots: Bottle.roots).first
        let added = hideLossless ? nil : LosslessFile.installed
        status.losslessDLL = added ?? status.lossless?.dll
        let losslessDetail: String
        if added != nil { losslessDetail = "Your copy, added from disk" }
        else if let steam = status.lossless { losslessDetail = "Steam build \(steam.buildID ?? "?") in bottle \(steam.bottle.lastPathComponent)" }
        else { losslessDetail = "Optional: adds frame generation and display scaling. Install it with Steam inside a CrossOver bottle, or add Lossless.dll from your copy (any store)." }
        checks.append(Check(id: "lossless", title: "Lossless Scaling", detail: losslessDetail,
                            state: status.losslessDLL == nil ? .optional : .ok,
                            fix: added != nil ? .removeLossless : status.lossless == nil ? .addLossless(store: LosslessScaling.store) : nil))

        if let dll = status.losslessDLL {
            let build = added != nil ? "your copy added from disk" : "Steam build \(status.lossless?.buildID ?? "?")"
            checks += kernelChecks(dll: dll, build: build)
        }

        let hook = HookFiles.source
        checks.append(Check(id: "hook", title: "Game hook", detail: hook == nil ? "Missing from the app; rebuild it" : "Included",
                            state: hook == nil ? .missing : .ok))
        status.checks = checks
        return status
    }

    /// The app ships every kernel pre-built, without Lossless Scaling's numbers (read from the user's copy when a
    /// game loads them); nothing is built on this Mac. They fit the Lossless Scaling versions they were built from;
    /// a Lossless Scaling update that changes a shader needs a Lightscale update.
    /// `build` names the user's copy in the message, so they can report which version isn't supported.
    private static func kernelChecks(dll: URL, build: String) -> [Check] {
        let baked = HookFiles.source?.appending(path: "baked")
        let fm = FileManager.default
        func fits(_ manifest: String, _ mismatches: (URL) throws -> [UInt32]) -> Bool {
            guard let baked, fm.fileExists(atPath: baked.appending(path: manifest).path) else { return false }
            return (try? mismatches(baked))?.isEmpty == true
        }
        // Not "newer": an older copy, a Steam beta branch or another store's build doesn't fit either.
        let update = "\(AppName.display) doesn't support your Lossless Scaling version yet (\(build)). Check for updates, or open an issue saying which version you have."
        let frameGeneration = fits(LSFGKernels.manifestName) { try LSFGKernels.bakedMismatches(bakedDirectory: $0, dll: dll, ids: kernelIDs) }
        let scaling = fits(LSFGKernels.dxbcManifestName) { try LSFGKernels.dxbcBakedMismatches(bakedDirectory: $0, dll: dll) }
        return [
            Check(id: "kernels", title: "Frame generation",
                  detail: frameGeneration ? "Ready for your Lossless Scaling version" : update, state: frameGeneration ? .ok : .missing),
            Check(id: "scaling", title: "Display scaling",
                  detail: scaling ? "Ready for your Lossless Scaling version" : update, state: scaling ? .ok : .missing),
        ]
    }
}
