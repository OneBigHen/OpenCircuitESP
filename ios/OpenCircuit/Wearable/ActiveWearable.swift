import Foundation
import Observation
import OpenCircuitKit

/// The one active wearable (#214, docs/DEVICE_SEAM.md). v1 allows ONE device at a time, and today
/// that is always the connected RingConn ring: `session` is `RingScanner.shared.session`, read
/// through a closure so constructing this never constructs the scanner.
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

    /// - Parameters:
    ///   - session: the active session, if any.
    ///   - fallbackDeviceID: the device to attribute writes to while no session exists (a flush in a
    ///     cold background launch, or after a disconnect).
    init(session: @escaping @MainActor () -> (any WearableSession)? = { RingScanner.shared.session },
         fallbackDeviceID: @escaping @MainActor () -> String? = { ActiveWearable.lastRingID() },
         identityStore: WearableIdentityStore = WearableIdentityStore()) {
        self.currentSession = session
        self.fallbackDeviceID = fallbackDeviceID
        self.identityStore = identityStore
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
        if let live = session?.identity {
            let previous = identityStore.load(id: live.id)
            if previous == nil, live.firmwareVersion == nil { return nil }
            let merged = live.merging(previous: previous)
            if merged != previous { identityStore.save(merged) }
            return merged
        }
        guard let id = fallbackDeviceID(), !id.isEmpty else { return nil }
        return identityStore.load(id: id)
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
