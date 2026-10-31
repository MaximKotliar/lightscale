import Foundation
import LSFGCore
import Metal

/// One line of the setup checklist.
struct Check: Identifiable, Sendable {
    enum State: Sendable { case ok, missing }
    enum Fix: Sendable, Equatable {
        case buildKernels
        case command(String)
        case open(URL)
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
    var checks: [Check] = []

    var problems: [Check] { checks.filter { $0.state == .missing } }
    var isReady: Bool { !checks.isEmpty && problems.isEmpty }
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

        status.lossless = LosslessLocator.findAll().first
        checks.append(Check(id: "lossless", title: "Lossless Scaling",
                            detail: status.lossless.map { "Steam build \($0.buildID ?? "?") in bottle \($0.bottle.lastPathComponent)" }
                                ?? "Install it with Steam inside a CrossOver bottle",
                            state: status.lossless == nil ? .missing : .ok,
                            fix: status.lossless == nil ? .open(URL(string: "https://store.steampowered.com/app/993090/")!) : nil))

        if let dll = status.lossless?.dll { checks.append(await kernelCheck(dll: dll)) }

        let hook = HookFiles.source
        checks.append(Check(id: "hook", title: "Game hook", detail: hook == nil ? "Missing from the app; rebuild it" : "Included",
                            state: hook == nil ? .missing : .ok))
        status.checks = checks
        return status
    }

    /// Kernels: pre-built ones (weights from the user's DLL) when they match this Lossless Scaling
    /// version, otherwise built on this Mac, which needs spirv-cross and Xcode's Metal compiler.
    private static func kernelCheck(dll: URL) async -> Check {
        if let baked = HookFiles.source?.appending(path: "baked"),
           FileManager.default.fileExists(atPath: baked.appending(path: LSFGKernels.manifestName).path),
           (try? LSFGKernels.bakedMismatches(bakedDirectory: baked, dll: dll, ids: kernelIDs))?.isEmpty == true {
            return Check(id: "kernels", title: "Frame generation", detail: "Ready for your Lossless Scaling version", state: .ok)
        }
        if ShaderTranslator.isTranslated(dll: dll) {
            return Check(id: "kernels", title: "Frame generation", detail: "Built on this Mac for your Lossless Scaling version", state: .ok)
        }
        if Shell.which("spirv-cross") == nil {
            return Check(id: "kernels", title: "Frame generation",
                         detail: "Your Lossless Scaling version needs a one-time build. Install the shader converter first.",
                         state: .missing, fix: .command("brew install spirv-cross"))
        }
        let metal = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["-sdk", "macosx", "-f", "metal"])
        if metal?.succeeded != true {
            return Check(id: "kernels", title: "Frame generation",
                         detail: "Your Lossless Scaling version needs a one-time build. Install Xcode's Metal compiler first.",
                         state: .missing, fix: .command("xcodebuild -downloadComponent MetalToolchain"))
        }
        return Check(id: "kernels", title: "Frame generation",
                     detail: "Your Lossless Scaling version needs a one-time build (about 10 seconds).",
                     state: .missing, fix: .buildKernels)
    }
}
