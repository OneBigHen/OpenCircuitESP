import Foundation
import Observation
import OpenCircuitKit

/// The one active wearable (#214, docs/DEVICE_SEAM.md). v1 allows ONE device at a time: the device
/// `ActiveDeviceChoiceStore` names (#215). `session` is `RingScanner.shared.session` or
/// `HelioConnection.shared.session`, read through a closure so constructing this never constructs
/// either driver, and the inactive driver is never touched.
///
/// Injected at the composition root (`App.swift`). No view reads it yet — views keep using
/// `RingSession` concretely until the Helio driver retypes them. Its first consumer is
/// `HealthKitWriter`, which names this device on every sample it saves.
@Observable
@MainActor
final class ActiveWearable {
    static let shared = ActiveWearable()

    @ObservationIgnored private let currentSession: @MainActor () -> (any WearableSession)?
    @ObservationIgnored private let fallbackDeviceID: @MainActor () -> String?
    @ObservationIgnored private let identityStore: WearableIdentityStore
    @ObservationIgnored private let ringFallbackID: @MainActor () -> String?
    @ObservationIgnored private let strapFallbackID: @MainActor () -> String?
    @ObservationIgnored private let ownership: @MainActor () -> DeviceOwnershipLog

    /// - Parameters:
    ///   - session: the active session, if any.
    ///   - fallbackDeviceID: the device to attribute writes to while no session exists (a flush in a
    ///     cold background launch, or after a disconnect).
    ///   - ringFallbackID / strapFallbackID: each family's last device, for attributing its rows while
    ///     it isn't the connected one (decision 28).
    ///   - ownership: who owned which time (decision 28).
    init(session: @escaping @MainActor () -> (any WearableSession)? = { ActiveWearable.activeDeviceSession() },
         fallbackDeviceID: @escaping @MainActor () -> String? = { ActiveWearable.lastActiveDeviceID() },
         identityStore: WearableIdentityStore = WearableIdentityStore(),
         ringFallbackID: @escaping @MainActor () -> String? = { ActiveWearable.ringIDForAttribution() },
         strapFallbackID: @escaping @MainActor () -> String? = { HelioConnection.savedPeripheralID },
         ownership: @escaping @MainActor () -> DeviceOwnershipLog = { LocalStore.ownershipLog() }) {
        self.currentSession = session
        self.fallbackDeviceID = fallbackDeviceID
        self.identityStore = identityStore
        self.ringFallbackID = ringFallbackID
        self.strapFallbackID = strapFallbackID
        self.ownership = ownership
    }

    /// The active device's session, or nil while nothing is connected.
    var session: (any WearableSession)? { currentSession() }

    /// What the active device can do; empty while nothing is connected.
    var capabilities: WearableCapabilities { session?.capabilities ?? [] }

    /// The identity to name on a Health write, or nil when there is none to name yet: no device has
    /// ever been known, or the connected one hasn't identified itself.
    ///
    /// Merged with (and recorded into) the last identity persisted for the same device id, so once a
    /// full identity has been persisted, a field known once is never dropped again for that device —
    /// a flush before this connection's DIS reads land, or with the ring out of range, still names it
    /// in full. See `WearableIdentity.merging(previous:)`.
    ///
    /// The merge can't help on a device's FIRST connection, when nothing is persisted: a write that
    /// lands before the firmware read would name a sparser device than every later write, and Apple
    /// Health would list it twice. So until the device has reported a firmware version, with nothing
    /// persisted, this returns nil and records nothing, and the write carries no device — exactly
    /// what every write did before the seam.
    func identityForHealthWrite() -> WearableIdentity? {
        if let live = session?.identity { return recordIdentity(live) }
        guard let id = fallbackDeviceID(), !id.isEmpty else { return nil }
        return identityStore.load(id: id)
    }

    /// Merge a live identity with the one persisted for its device and record it; nil under the
    /// first-write guard (nothing persisted yet and no firmware version), which records nothing.
    /// Per device: each device id has its own persisted identity and its own guard.
    @discardableResult
    func recordIdentity(_ live: WearableIdentity) -> WearableIdentity? {
        let previous = identityStore.load(id: live.id)
        if previous == nil, live.firmwareVersion == nil { return nil }
        let merged = live.merging(previous: previous)
        if merged != previous { identityStore.save(merged) }
        return merged
    }

    /// The identity for rows on `timeline` (decision 28: attribution follows the ROW, never the
    /// current choice). The live session's when it is that device's, else that device's persisted
    /// identity. nil when the device never passed the first-write guard.
    func identityForHealthWrite(timeline: SyncDeviceID) -> WearableIdentity? {
        if let live = session?.identity, SyncDeviceID.timeline(for: live.kind, identityID: live.id) == timeline {
            return recordIdentity(live)
        }
        let id: String?
        switch DeviceOwnershipLog.Family(timeline: timeline) {
        case .ringConn: id = ringFallbackID()
        case .zeppOS: id = Self.strapID(of: timeline)
        }
        guard let id, !id.isEmpty else { return nil }
        return identityStore.load(id: id)
    }

    /// The identity for an UNTAGGED row at `date` (steps, sleep, naps, derived resting HR and
    /// energy): the device that owned `date` (decision 28). For a ring-only install that is always the
    /// ring, so this is exactly `identityForHealthWrite()` with the ring chosen.
    func identityForHealthWrite(at date: Date) -> WearableIdentity? {
        switch ownership().owner(at: date) {
        case .ringConn:
            return identityForHealthWrite(timeline: .ringConn)
        case .zeppOS:
            guard let id = strapFallbackID(), !id.isEmpty else { return nil }
            return identityForHealthWrite(timeline: SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: id))
        }
    }

    /// The strap's peripheral id inside its timeline (`zeppos:<id>`).
    static func strapID(of timeline: SyncDeviceID) -> String? {
        let prefix = "zeppos:"
        guard timeline.rawValue.hasPrefix(prefix) else { return nil }
        return String(timeline.rawValue.dropFirst(prefix.count))
    }

    /// The ring's id for attribution. With the ring chosen, exactly `lastRingID()`; with the strap
    /// chosen, the same answer read without constructing the ring's scanner.
    static func ringIDForAttribution() -> String? {
        if ActiveDeviceChoiceStore.shared.isRing { return lastRingID() }
        if let active = RingScanner.persistedActiveRingID, !active.isEmpty { return active }
        let cached = RingMetadataStore().load().identifier
        return cached.isEmpty ? nil : cached
    }

    /// The chosen device's live session (decision 1: the other driver is not read, so not created).
    static func activeDeviceSession() -> (any WearableSession)? {
        switch ActiveDeviceChoiceStore.shared.current {
        case .ringConn: return RingScanner.shared.session
        case .helioStrap: return HelioConnection.shared.session
        }
    }

    /// The chosen device writes would come from while it isn't connected.
    static func lastActiveDeviceID() -> String? {
        switch ActiveDeviceChoiceStore.shared.current {
        case .ringConn: return lastRingID()
        case .helioStrap: return HelioConnection.savedPeripheralID
        }
    }

    /// The ring writes would come from while none is connected: the one set to auto-reconnect,
    /// else the last one connected (cleared to nil by an explicit user stop, which keeps the
    /// metadata cache).
    static func lastRingID() -> String? {
        if let active = RingScanner.shared.activeRingID, !active.isEmpty { return active }
        let cached = RingMetadataStore().load().identifier
        return cached.isEmpty ? nil : cached
    }
}

/// The last identity seen per device id. UserDefaults-backed, like `RingMetadataStore`: a few short
/// strings, no schema, no migration risk. Holds no MAC-derived byte (see `WearableIdentity`).
struct WearableIdentityStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func key(_ id: String) -> String { "wearable.identity.v1.\(id)" }

    func load(id: String) -> WearableIdentity? {
        guard let data = defaults.data(forKey: Self.key(id)) else { return nil }
        return try? JSONDecoder().decode(WearableIdentity.self, from: data)
    }

    func save(_ identity: WearableIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: Self.key(identity.id))
    }
}
