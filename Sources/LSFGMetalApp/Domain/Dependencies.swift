import Foundation
import LSFGCore
import Metal

/// One line of the Setup checklist.
struct Check: Identifiable, Sendable {
    enum State: Sendable { case ok, warning, missing }
    enum Fix: Sendable, Equatable {
        case translateShaders
        case command(String)
        case open(URL)
    }

    let id: String
    let title: String
    let detail: String
    let state: State
    var fix: Fix?
}

/// What the Setup screen and the installer need to know about this Mac.
struct SystemStatus: Sendable {
    var crossOver: CrossOverInstall?
    var lossless: LosslessInstall?
    var checks: [Check] = []

    var isReady: Bool { checks.allSatisfy { $0.state != .missing } }
}

enum DependencyChecker {
    static func run() async -> SystemStatus {
        var env = SystemStatus()
        var checks: [Check] = []

        let device = MTLCreateSystemDefaultDevice()
        let appleGPU = device?.supportsFamily(.apple7) == true
        checks.append(Check(id: "gpu", title: "Apple GPU", detail: device?.name ?? "No Metal device",
                            state: appleGPU ? .ok : .missing))

        env.crossOver = CrossOverInstall.find()
        checks.append(Check(id: "crossover", title: "CrossOver",
                            detail: env.crossOver.map { "Version \($0.version)" } ?? "Not found in Applications",
                            state: env.crossOver == nil ? .missing : .ok,
                            fix: env.crossOver == nil ? .open(URL(string: "https://www.codeweavers.com/crossover")!) : nil))

        env.lossless = LosslessLocator.findAll().first
        checks.append(Check(id: "lossless", title: "Lossless Scaling (Steam)",
                            detail: env.lossless.map { "Bottle \($0.bottle.lastPathComponent), build \($0.buildID ?? "?")" }
                                ?? "Install it with Steam inside a CrossOver bottle",
                            state: env.lossless == nil ? .missing : .ok,
                            fix: env.lossless == nil ? .open(URL(string: "https://store.steampowered.com/app/993090/")!) : nil))

        let spirvCross = Shell.which("spirv-cross")
        checks.append(Check(id: "spirv", title: "Shader converter", detail: spirvCross?.path ?? "spirv-cross not installed",
                            state: spirvCross == nil ? .missing : .ok,
                            fix: spirvCross == nil ? .command("brew install spirv-cross") : nil))

        let metal = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["-sdk", "macosx", "-f", "metal"])
        let hasMetal = metal?.succeeded == true
        checks.append(Check(id: "metal", title: "Metal compiler",
                            detail: hasMetal ? "Xcode Metal toolchain" : "Needs Xcode's Metal toolchain",
                            state: hasMetal ? .ok : .missing,
                            fix: hasMetal ? nil : .command("xcodebuild -downloadComponent MetalToolchain")))

        if let dll = env.lossless?.dll {
            let translated = ShaderTranslator.isTranslated(dll: dll)
            checks.append(Check(id: "shaders", title: "LSFG shaders",
                                detail: translated ? "Translated from your Lossless.dll" : "Not translated for this Lossless.dll yet",
                                state: translated ? .ok : .missing, fix: translated ? nil : .translateShaders))
        }

        let hook = HookFiles.source
        checks.append(Check(id: "hook", title: "Hook files", detail: hook == nil ? "Missing: rebuild with scripts/build-app.sh" : "Bundled",
                            state: hook == nil ? .missing : .ok))

        env.checks = checks
        return env
    }
}
