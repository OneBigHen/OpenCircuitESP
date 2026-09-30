import Foundation
import Observation

/// Which wearable the app drives (#215, decision 1): ONE at a time. The inactive device is not
/// scanned for, connected or synced. Switching keeps both devices' stored history, because every
/// device writes its own timeline (`SyncDeviceID`, SchemaV8).
enum ActiveDeviceChoice: String, CaseIterable, Sendable {
    case ringConn
    case helioStrap

    var displayName: String {
        switch self {
        case .ringConn: return "RingConn ring"
        case .helioStrap: return "Amazfit Helio Strap"
        }
    }
}

/// The persisted choice (UserDefaults). `.ringConn` when nothing was ever chosen, so an existing
/// ring user's app is exactly what it was before the strap existed.
@Observable
@MainActor
final class ActiveDeviceChoiceStore {
    static let shared = ActiveDeviceChoiceStore()
    nonisolated static let key = "device.activeChoice.v1"

    /// The choice read straight from UserDefaults, for launch paths that must decide before any
    /// observable holder exists (AppDelegate, a BGTask, a CoreBluetooth-restoration relaunch).
    nonisolated static func persisted(_ defaults: UserDefaults = .standard) -> ActiveDeviceChoice {
        defaults.string(forKey: key).flatMap(ActiveDeviceChoice.init(rawValue:)) ?? .ringConn
    }

    private(set) var current: ActiveDeviceChoice
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = Self.persisted(defaults)
    }

    var isRing: Bool { current == .ringConn }
    var isHelio: Bool { current == .helioStrap }

    /// Persist a choice. Only `DeviceSwitcher` calls this: switching also stops the other device.
    func set(_ choice: ActiveDeviceChoice) {
        defaults.set(choice.rawValue, forKey: Self.key)
        current = choice
    }
}

/// The one place the active device changes (decision 1).
@MainActor
enum DeviceSwitcher {
    /// Stop the device being left (no scan, no link, no pending connect), persist the choice, then
    /// wake the device being chosen. The device being left keeps its saved peripheral, so switching
    /// back reconnects without a new pairing.
    static func activate(_ choice: ActiveDeviceChoice, store: ActiveDeviceChoiceStore? = nil) {
        let store = store ?? .shared
        guard choice != store.current else { return }
        switch choice {
        case .helioStrap:
            // Constructs the scanner if this launch never touched it; that creates no central
            // (RingScanner #142) and happens before the strap becomes active.
            RingScanner.shared.disconnect()
            store.set(.helioStrap)
            HelioConnection.shared.reconnectKnown()
        case .ringConn:
            HelioConnection.shared.disconnect()
            store.set(.ringConn)
            RingScanner.shared.reconnectKnownPeripheral()
        }
    }
}

/// Which drain a background wake runs (decision 1): the chosen device's, never the other's. The BGTask
/// handler and the Sleep Focus filter decide with it from the persisted choice (UserDefaults only)
/// before touching either driver, so with the strap chosen the ring's scanner and central are never
/// constructed, and with the ring chosen the strap's connection and central never are.
enum BackgroundDrain: Equatable {
    case ring
    case strap

    init(_ choice: ActiveDeviceChoice) {
        switch choice {
        case .ringConn: self = .ring
        case .helioStrap: self = .strap
        }
    }
}
