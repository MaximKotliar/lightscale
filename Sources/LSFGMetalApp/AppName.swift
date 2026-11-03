import Foundation

/// The app's name in one place. "Lightscale" is a working name; the final rename only touches this file,
/// scripts/build-app.sh (bundle name and ID) and the hook's folder and log names (hook/unix, hook/install.sh).
enum AppName {
    static let display = "Lightscale"
    /// ~/Library/Application Support/<folder>, ~/Library/Logs/<folder>.log
    static let folder = "Lightscale"
    /// Bundle ID before the rename, for settings saved by the old app
    static let legacyBundleID = "dev.lsfg-metal.setup"
}
