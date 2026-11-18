import Foundation
import Security

/// URL/insecure live in defaults; the API password is kept in the login
/// keychain under a service specific to this local build.
enum PiHoleCredentials {
    static let service = "com.egressatlas.pihole"
    static let account = "api-password"
    private static let urlKey = "egress-atlas.pihole.url.v1"
    private static let insecureKey = "egress-atlas.pihole.insecure.v1"
    private static let populationKey = "egress-atlas.pihole.population.v1"
    private static let populationVersionKey = "egress-atlas.pihole.population.version"
    private static let populationVersion = 2
    private static let sourceModeKey = "egress-atlas.source.live.v1"

    static var savedURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    static var savedInsecure: Bool {
        get { UserDefaults.standard.bool(forKey: insecureKey) }
        set { UserDefaults.standard.set(newValue, forKey: insecureKey) }
    }

    static var livePopulation: LivePopulation {
        get {
            let defaults = UserDefaults.standard
            let raw = defaults.string(forKey: populationKey) ?? ""
            // Version 1 had only All/Top 12, and All was the implicit default.
            // Move that legacy value to the new finite default; a deliberate
            // switch back to All remains available in the Source panel.
            if defaults.integer(forKey: populationVersionKey) < populationVersion {
                let migrated: LivePopulation
                if raw == "focused" {
                    migrated = .top25
                } else if raw == "all" {
                    migrated = .defaultChoice
                } else {
                    migrated = LivePopulation.stored(raw) ?? .defaultChoice
                }
                defaults.set(migrated.storageValue, forKey: populationKey)
                defaults.set(populationVersion, forKey: populationVersionKey)
                return migrated
            }
            return LivePopulation.stored(raw) ?? .defaultChoice
        }
        set {
            UserDefaults.standard.set(newValue.storageValue, forKey: populationKey)
            UserDefaults.standard.set(populationVersion, forKey: populationVersionKey)
        }
    }

    /// The source the app was showing when it last switched/quits. The launch
    /// path uses this to reconnect to Pi-hole instead of always opening demo.
    static var lastSourceWasLive: Bool {
        get { UserDefaults.standard.bool(forKey: sourceModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: sourceModeKey) }
    }

    static var hasPassword: Bool {
        password?.isEmpty == false
    }

    static var password: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(password value: String) throws {
        guard !value.isEmpty else { return }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PiHoleError.auth("Could not save the Pi-hole password in the Keychain (\(addStatus)).")
            }
        } else if status != errSecSuccess {
            throw PiHoleError.auth("Could not update the Pi-hole password in the Keychain (\(status)).")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: insecureKey)
        UserDefaults.standard.set(false, forKey: sourceModeKey)
    }
}
