import Foundation

/// The app's name in one place. "Lightscale" is a working name; the final rename only touches this file,
/// scripts/build-app.sh (bundle name and ID) and the hook's folder and log names (hook/unix, hook/install.sh).
enum AppName {
    static let display = "Lightscale"
    /// ~/Library/Application Support/<folder>, ~/Library/Logs/<folder>.log
    static let folder = "Lightscale"
    /// Every bundle ID this app has had, the current one first (scripts/build-app.sh sets it). The updater accepts a
    /// release under any of them. com.maksystems.lightscale: 0.19, withdrawn on the day; its copies update back.
    static let bundleIDs = ["dev.lightscale.app", "com.maksystems.lightscale", "dev.lsfg-metal.setup"]
    /// Settings the app keeps in UserDefaults, which macOS stores per bundle ID.
    static let settingKeys = ["setupComplete", "bottleFolders"]

    /// Copies settings saved under the app's earlier bundle IDs into this one's, where it has none of its own.
    static func migrateSettings(to defaults: UserDefaults = .standard, current: String? = Bundle.main.bundleIdentifier,
                                from ids: [String] = bundleIDs) {
        for id in ids where id != current {
            guard let old = UserDefaults(suiteName: id) else { continue }
            for key in settingKeys where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
    }
}
