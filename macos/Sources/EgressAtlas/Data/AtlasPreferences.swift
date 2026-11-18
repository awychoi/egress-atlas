import Foundation

/// Durable display and motion preferences. Source connection state stays in
/// `PiHoleCredentials` because the password belongs in the Keychain; these are
/// the options the Settings panel should restore on the next launch.
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
}
