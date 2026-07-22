import Foundation

/// Associates the single persisted manual board rectangle with the exact
/// capture source it was made for. The recognition model remains untouched;
/// this only prevents a rectangle from one client/display being applied to
/// another one.
enum BoardGeometrySourceStore {
    private static let sourceKeyKey = "BoardGeometryCaptureSourceKey"
    private static let bundleIdentifierKey =
        "BoardGeometrySourceBundleIdentifier"

    static var sourceKey: String? {
        WindowCandidatePolicy.normalizedText(
            UserDefaults.standard.string(forKey: sourceKeyKey)
        )
    }

    /// Read-only compatibility hook for builds that stored only a bundle ID.
    static var legacyBundleIdentifier: String? {
        WindowCandidatePolicy.normalizedText(
            UserDefaults.standard.string(forKey: bundleIdentifierKey)
        )
    }

    static func windowSourceKey(
        bundleIdentifier: String?,
        applicationName: String?
    ) -> String? {
        if let bundleIdentifier = WindowCandidatePolicy.normalizedIdentifier(
            bundleIdentifier
        ) {
            return "window:bundle:\(bundleIdentifier)"
        }
        if let applicationName = WindowCandidatePolicy.normalizedText(
            applicationName
        )?.lowercased() {
            return "window:app:\(applicationName)"
        }
        return nil
    }

    static func displaySourceKey(displayID: UInt32) -> String {
        "display:\(displayID)"
    }

    static func save(sourceKey: String) {
        UserDefaults.standard.set(sourceKey, forKey: sourceKeyKey)
        UserDefaults.standard.removeObject(forKey: bundleIdentifierKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: sourceKeyKey)
        UserDefaults.standard.removeObject(forKey: bundleIdentifierKey)
    }
}
