import Foundation

/// The app's ID was com.capturecampmemories.cardingest before it was renamed
/// Media Sherpa, and macOS keeps preferences under the ID: the license key, the
/// tutorial having been seen, keyboard shortcuts. The first time the renamed app
/// runs, they're moved across, so nobody has to enter the key again.
public enum PreferencesMove {
    public static let appID = "com.capturecampmedia.mediasherpa"
    public static let oldAppIDs = ["com.capturecampmemories.cardingest"]

    /// Copies the first old ID's preferences to `newID` when `newID` has none yet, then
    /// removes the old ones. True if something was moved.
    @discardableResult
    public static func moveOld(to newID: String, from oldIDs: [String] = oldAppIDs,
                               defaults: UserDefaults = .standard) -> Bool {
        if let current = defaults.persistentDomain(forName: newID), !current.isEmpty { return false }
        for old in oldIDs {
            guard let values = defaults.persistentDomain(forName: old), !values.isEmpty else { continue }
            defaults.setPersistentDomain(values, forName: newID)
            defaults.removePersistentDomain(forName: old)
            return true
        }
        return false
    }
}
