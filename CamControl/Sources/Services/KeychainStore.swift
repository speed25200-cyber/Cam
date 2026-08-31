import Foundation
import Security

/// Per-camera credentials, stored in the iOS Keychain.
///
/// Never `UserDefaults` and never the `Camera` model: the camera list is written
/// to disk as plain JSON, and a password in it would end up in the device backup
/// in the clear.
enum KeychainStore {
    private static let service = "com.local.camcontrol.cameras"

    @discardableResult
    static func save(_ credentials: CameraCredentials, for key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Update in place when the item exists, so its access group and creation
        // date survive a password change.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData as String] = data
        // The app must be able to reconnect after a reboot without the device
        // being unlocked first, but the item must not travel to other devices.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(for key: String) -> CameraCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CameraCredentials.self, from: data)
    }

    static func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Wipes every stored credential — the "forget all cameras" path in Settings.
    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
