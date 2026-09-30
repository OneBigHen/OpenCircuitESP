import Foundation
import Observation
import OpenCircuitKit
import SwiftData

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
    @ObservationIgnored private let ownership: DeviceOwnershipStore
    @ObservationIgnored private let neverHadRing: @MainActor () -> Bool

    init(defaults: UserDefaults = .standard, ownership: DeviceOwnershipStore? = nil,
         neverHadRing: (@MainActor () -> Bool)? = nil) {
        self.defaults = defaults
        // A store over its own defaults (a test's suite) records its switches there too.
        self.ownership = ownership ?? (defaults === UserDefaults.standard ? .shared : DeviceOwnershipStore(defaults: defaults))
        self.neverHadRing = neverHadRing ?? { DeviceOwnershipStore.installNeverHadRing() }
        current = Self.persisted(defaults)
    }

    var isRing: Bool { current == .ringConn }
    var isHelio: Bool { current == .helioStrap }

    /// Persist a choice. Only `DeviceSwitcher` calls this: switching also stops the other device.
    ///
    /// The ONE place a switch is recorded in the ownership log (decision 28), and only when the
    /// choice actually changes. The strap's first entry on an install that never had a ring owns
    /// all past time (`.distantPast`), so a strap-only user gets the normal first sync; every other
    /// switch owns time from `now`.
    func set(_ choice: ActiveDeviceChoice, now: Date = Date()) {
        defaults.set(choice.rawValue, forKey: Self.key)
        if choice != current {
            let family: DeviceOwnershipLog.Family = choice == .ringConn ? .ringConn : .zeppOS
            let strapOnly = family == .zeppOS && ownership.log.isEmpty && neverHadRing()
            ownership.record(family, since: strapOnly ? .distantPast : now)
        }
        current = choice
    }
}

/// Decision 28's ownership log, persisted in UserDefaults under a versioned key (no SwiftData
/// schema change). Written only through `ActiveDeviceChoiceStore.set`; read by the store, the
/// strap's fetch and the Health writer.
@MainActor
final class DeviceOwnershipStore {
    static let shared = DeviceOwnershipStore()
    nonisolated static let key = "device.ownershipLog.v1"

    private let defaults: UserDefaults
    /// The persisted log; empty (the ring owns all time) when nothing was ever switched.
    private(set) var log: DeviceOwnershipLog

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        log = Self.persisted(defaults)
    }

    nonisolated static func persisted(_ defaults: UserDefaults = .standard) -> DeviceOwnershipLog {
        guard let data = defaults.data(forKey: key),
              let log = try? JSONDecoder().decode(DeviceOwnershipLog.self, from: data) else { return DeviceOwnershipLog() }
        return log
    }

    func record(_ family: DeviceOwnershipLog.Family, since: Date) {
        var next = log
        guard next.record(family, since: since), let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
        log = next
    }

    /// "Never had a ring" (decision 28's first-entry rule): no saved ring peripheral, no cached ring
    /// identity (`RingMetadataStore`), and no sample row on the ring's timeline. Without a readable
    /// store the answer is "had a ring", the conservative side: the strap then owns time only from
    /// the switch.
    static func installNeverHadRing(defaults: UserDefaults = .standard) -> Bool {
        guard !RingScanner.hasSavedRingToRestore, RingMetadataStore(defaults).load().identifier.isEmpty,
              let container = OpenCircuitApp.sharedContainer else { return false }
        let ring = SyncDeviceID.ringConn.rawValue
        var descriptor = FetchDescriptor<StoredSample>(predicate: #Predicate { $0.deviceID == ring })
        descriptor.fetchLimit = 1
        guard let rows = try? container.mainContext.fetch(descriptor) else { return false }
        return rows.isEmpty
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
