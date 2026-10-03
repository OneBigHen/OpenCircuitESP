import Foundation
import Security

// Before the first unlock after a restart, the Shortcuts actions can't read what they need: the device
// choice and the strap's state are in UserDefaults (data protection: available only after the first
// unlock), and the strap's key is in the Keychain as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
// (decision 5). Read then, the choice would come back as the ring and the key as missing (review-261 F2).
// So in that one window every action answers "unlock once" and does nothing.
//
// It must be ONLY that window (steer 4). `UIApplication.isProtectedDataAvailable` is false whenever a
// passcode-protected phone is locked, which is exactly when a Message or bedtime automation runs, so it
// is not used. Instead a Keychain sentinel with the same accessibility class as the strap's key:
// Apple documents that class as "The data in the keychain item cannot be accessed after a restart until
// the device has been unlocked once by the user. After the first unlock, the data remains accessible
// until the next restart."
// (https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
// A read refused for that reason returns `errSecInteractionNotAllowed` ("Interaction with the Security
// Server is not allowed.", https://developer.apple.com/documentation/security/errsecinteractionnotallowed).
// So the sentinel opens at the same moment the strap's key does, and a locked phone after the first
// unlock reads it fine.
//
// Why not a file with `FileProtectionType.completeUntilFirstUserAuthentication`: that class is documented
// for the same window, but a refused read surfaces as a generic file error rather than one status that
// names the reason, and the Keychain class is the very one the key the actions depend on uses. A
// UserDefaults sentinel is ruled out (steer 4): before the first unlock a write can be served back from
// memory without reaching disk.

/// What a read of the sentinel says.
enum FirstUnlockProbe: Equatable {
    /// Read: the first unlock since boot has happened (the phone may be locked again now).
    case readable
    /// No sentinel yet (a first launch, or a reinstall). Proceed: nothing says the data is unreadable.
    case missing
    /// `errSecInteractionNotAllowed`: the phone hasn't been unlocked since it restarted.
    case beforeFirstUnlock
    /// Any other status (e.g. `-34018` in an unsigned test run). Proceed, and log it.
    case failed(OSStatus)
}

/// The pure decision over a probe: refuse only before the first unlock since boot.
enum FirstUnlockGate {
    enum Verdict: Equatable {
        case proceed
        case refuse
    }

    static func verdict(for probe: FirstUnlockProbe) -> Verdict {
        switch probe {
        case .beforeFirstUnlock: return .refuse
        case .readable, .missing, .failed: return .proceed
        }
    }
}

/// The Keychain item itself. One byte of data, never anything personal.
struct FirstUnlockSentinel {
    nonisolated static let defaultService = "com.standardsoftwaresolutions.opencircuit.firstUnlockSentinel"
    let service: String
    let account = "sentinel"

    init(service: String = FirstUnlockSentinel.defaultService) {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Reads the item's DATA (attributes alone could be answered without the class key).
    func probe() -> FirstUnlockProbe {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .readable
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed: return .beforeFirstUnlock
        default: return .failed(status)
        }
    }

    /// Creates the sentinel when it's missing (a normal launch, and an action that proceeds). Before the
    /// first unlock the add fails harmlessly and the next launch tries again. Returns the add's status
    /// (`errSecSuccess` when it already existed).
    @discardableResult
    func ensure() -> OSStatus {
        guard probe() == .missing else { return errSecSuccess }
        var item = query
        item[kSecValueData as String] = Data([1])
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    /// Tests only.
    func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
