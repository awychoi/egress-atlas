import Foundation

/// Durable display, motion and local-alias preferences. Source connection
/// state stays in `PiHoleCredentials` because the password belongs in the
/// Keychain; these are the options the app restores on the next launch.
///
/// Every getter returns `nil` when the key is absent so the runtime can apply
/// its own context-sensitive default (for example, auto-orbit follows the
/// system Reduce Motion setting on first run).
enum AtlasPreferences {
    /// Headless tools flip this off so rendering docs snapshots with
    /// `--window` or `--labels` cannot rewrite the user's preferences.
    static var persists = true

    private static var defaults: UserDefaults { .standard }

    private static let labelModeKey = "atlas.labelMode"
    private static let motionModeKey = "atlas.motionMode"
    private static let windowHoursKey = "atlas.windowHours"
    private static let autoOrbitKey = "atlas.autoOrbit"
    private static let windowDragSpinsGlobeKey = "atlas.windowDragSpinsGlobe"
    private static let recoilKey = "atlas.nodeRecoil"
    private static let speedKey = "atlas.studySpeed"
    private static let hitPlaneKey = "atlas.hitPlane"
    private static let deviceAliasesKey = "atlas.deviceAliases"
    private static let destinationAliasesKey = "atlas.destinationAliases"
    private static let showAliasWithAddressKey = "atlas.showAliasWithAddress"

    static var labelMode: LabelMode? {
        get {
            guard let raw = defaults.string(forKey: labelModeKey) else { return nil }
            return LabelMode(rawValue: raw)
        }
        set {
            guard persists, let newValue else { return }
            defaults.set(newValue.rawValue, forKey: labelModeKey)
        }
    }

    static var motionMode: MotionMode? {
        get {
            guard let raw = defaults.string(forKey: motionModeKey) else { return nil }
            return MotionMode(rawValue: raw)
        }
        set {
            guard persists, let newValue else { return }
            defaults.set(newValue.rawValue, forKey: motionModeKey)
        }
    }

    static var windowHours: Float? {
        get {
            guard defaults.object(forKey: windowHoursKey) != nil else { return nil }
            let value = Float(defaults.double(forKey: windowHoursKey))
            return value.isFinite ? value : nil
        }
        set {
            guard persists, let newValue else { return }
            defaults.set(Double(newValue), forKey: windowHoursKey)
        }
    }

    static var autoOrbit: Bool? {
        get { optionalBool(autoOrbitKey) }
        set { setOptionalBool(newValue, forKey: autoOrbitKey) }
    }

    static var windowDragSpinsGlobe: Bool? {
        get { optionalBool(windowDragSpinsGlobeKey) }
        set { setOptionalBool(newValue, forKey: windowDragSpinsGlobeKey) }
    }

    static var recoil: Bool? {
        get { optionalBool(recoilKey) }
        set { setOptionalBool(newValue, forKey: recoilKey) }
    }

    static var hitPlane: Bool? {
        get { optionalBool(hitPlaneKey) }
        set { setOptionalBool(newValue, forKey: hitPlaneKey) }
    }

    /// Local, user-authored display names for devices, keyed by IP because the
    /// live source rebuilds the graph from a fresh Pi-hole snapshot (and its
    /// synthetic device ids are not stable across populations).
    static var deviceAliases: [String: String] {
        get { aliases(deviceAliasesKey) }
        set { setAliases(newValue, forKey: deviceAliasesKey) }
    }

    /// Local display names for DNS destinations, keyed by domain.
    static var destinationAliases: [String: String] {
        get { aliases(destinationAliasesKey) }
        set { setAliases(newValue, forKey: destinationAliasesKey) }
    }

    /// When true, cards append the original IP/domain to an alias. The default
    /// is alias-only, matching the compact index.
    static var showAliasWithAddress: Bool? {
        get { optionalBool(showAliasWithAddressKey) }
        set { setOptionalBool(newValue, forKey: showAliasWithAddressKey) }
    }

    static var speed: Float? {
        get {
            guard defaults.object(forKey: speedKey) != nil else { return nil }
            let value = Float(defaults.double(forKey: speedKey))
            return value.isFinite ? value : nil
        }
        set {
            guard persists, let newValue else { return }
            defaults.set(Double(newValue), forKey: speedKey)
        }
    }

    private static func optionalBool(_ key: String) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    private static func setOptionalBool(_ value: Bool?, forKey key: String) {
        guard persists, let value else { return }
        defaults.set(value, forKey: key)
    }

    private static func aliases(_ key: String) -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func setAliases(_ value: [String: String], forKey key: String) {
        guard persists else { return }
        if value.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
