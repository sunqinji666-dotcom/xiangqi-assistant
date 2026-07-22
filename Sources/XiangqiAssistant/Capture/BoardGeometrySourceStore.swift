import Foundation

/// Associates the single persisted manual board rectangle with the exact
/// capture source it was made for. The recognition model remains untouched;
/// this only prevents a rectangle from one client/display being applied to
/// another one.
enum BoardGeometrySourceStore {
    private static let sourceKeyKey = "BoardGeometryCaptureSourceKey"
    private static let bundleIdentifierKey =
        "BoardGeometrySourceBundleIdentifier"
    /// Durable, per-application copies of manual rectangles.  The original
    /// implementation kept a single JSON file plus one source key, so framing
    /// a second client replaced the first client's rectangle and an accidental
    /// legacy-file removal left every client without a crop.  UserDefaults is
    /// a second persistence channel and lets each chess application retain its
    /// own rectangle.
    private static let geometryRegistryKey =
        "BoardGeometryByCaptureSource.v2"

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

    static func geometry(for sourceKey: String) -> BoardGeometry? {
        geometryRegistry()[sourceKey]
    }

    static func save(geometry: BoardGeometry, sourceKey: String) {
        var registry = geometryRegistry()
        registry[sourceKey] = geometry
        if let data = try? JSONEncoder().encode(registry) {
            UserDefaults.standard.set(data, forKey: geometryRegistryKey)
        }
        save(sourceKey: sourceKey)
        // Keep the historical file as an independent recovery copy and for
        // compatibility with earlier builds.
        geometry.save()
    }

    static func removeGeometry(for sourceKey: String) {
        var registry = geometryRegistry()
        registry.removeValue(forKey: sourceKey)
        if let data = try? JSONEncoder().encode(registry) {
            UserDefaults.standard.set(data, forKey: geometryRegistryKey)
        }
        if self.sourceKey == sourceKey {
            clear()
            BoardGeometry.delete()
        }
    }

    private static func geometryRegistry() -> [String: BoardGeometry] {
        guard let data = UserDefaults.standard.data(forKey: geometryRegistryKey),
              let registry = try? JSONDecoder().decode(
                [String: BoardGeometry].self,
                from: data
              )
        else { return [:] }
        return registry
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: sourceKeyKey)
        UserDefaults.standard.removeObject(forKey: bundleIdentifierKey)
    }
}
