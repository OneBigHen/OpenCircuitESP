import Foundation
import Security
import ZeppKit

/// Where the strap's 16-byte auth key lives (decisions 4, 5, 7).
@MainActor
protocol HelioKeyStoring: AnyObject {
    /// The saved key, or nil. Never logged, printed, exported or shown: `ZeppAuthKey` redacts itself.
    func load() -> ZeppAuthKey?
    /// Parse pasted text (`HelioKeyText`) and save it, replacing any saved key and clearing a
    /// "rejected" mark. Returns false, saving nothing, when the text is not a key.
    func save(pasted text: String) throws -> Bool
    func forget()
    /// The strap answered `10 05 25` to this key. Kept until the key is replaced or forgotten, so
    /// the app never retries a key the strap refused (decision 7).
    var isRejected: Bool { get }
    func markRejected()
}

extension HelioKeyStoring {
    var hasKey: Bool { load() != nil }
}

enum HelioKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// The Keychain-backed key store (decision 5): a generic password readable after the first unlock
/// on this device only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), so a background sync
/// can use it, and it never leaves the phone in a backup. The key is stored as its 32 normalised hex
/// digits, the only form `ZeppAuthKey` can be rebuilt from.
@MainActor
final class HelioKeyStore: HelioKeyStoring {
    static let shared = HelioKeyStore()

    nonisolated static let defaultService = "com.standardsoftwaresolutions.opencircuit.helio.authkey"
    static let rejectedKey = "helio.keyRejected.v1"

    private let service: String
    private let account: String
    private let defaults: UserDefaults

    init(service: String = defaultService, account: String = "helio-strap", defaults: UserDefaults = .standard) {
        self.service = service
        self.account = account
        self.defaults = defaults
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> ZeppAuthKey? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return HelioKeyText.parse(text)
    }

    func save(pasted text: String) throws -> Bool {
        guard let normalized = HelioKeyText.normalized(text) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(normalized.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HelioKeyStoreError.keychain(status) }
        defaults.removeObject(forKey: Self.rejectedKey)
        return true
    }

    func forget() {
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: Self.rejectedKey)
    }

    var isRejected: Bool { defaults.bool(forKey: Self.rejectedKey) }

    func markRejected() { defaults.set(true, forKey: Self.rejectedKey) }
}
