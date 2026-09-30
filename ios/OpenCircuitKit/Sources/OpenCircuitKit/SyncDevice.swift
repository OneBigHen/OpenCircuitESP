// Per-device sync bookkeeping (#214, docs/DEVICE_SEAM.md §3). A stored sample and a sync cursor
// now say which device's TIMELINE they belong to, so a second wearable's backfill is judged against
// its own watermark instead of the ring's — before this, `SyncCursor.selectNew` dropped any sample
// older than the kind's single global watermark, so a new device's history was silently discarded.
//
// Pure value types, so the rule that keeps the ring byte-for-byte unchanged is covered by `swift test`.

import Foundation

/// The timeline a stored sample or sync cursor belongs to.
///
/// NOT the per-install peripheral id. Every RingConn ring shares ONE timeline, exactly as it did
/// before this type existed: multi-ring is sequential and its data merges (`RingScanner`), so giving
/// each ring its own cursor would re-admit, and re-write to Apple Health, whatever a swapped-in ring
/// still holds from before the swap. Other device families get one timeline per device.
public struct SyncDeviceID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Every RingConn ring — and every row written before per-device cursors existed. The SchemaV8
    /// migration gives existing rows this value as a column default, so it is also what the live
    /// `@Model` defaults spell out literally; `SyncDeviceIDTests` pins the two together.
    public static let ringConn = SyncDeviceID(rawValue: "ringconn")

    /// The timeline a wearable writes into. `identityID` is `WearableIdentity.id`.
    public static func timeline(for kind: WearableDeviceKind, identityID: String) -> SyncDeviceID {
        switch kind {
        case .ringConn: return .ringConn
        case .zeppOS: return SyncDeviceID(rawValue: "zeppos:\(identityID)")
        }
    }
}

/// The persisted `StoredCursor` key for a cursor NAME (`heartRate`, `hk:heartRate`, …) on a device.
///
/// The ring's keys are the pre-V8 keys, unchanged. That is what lets the V7→V8 migration be a
/// lightweight one that rewrites no row (the build-44 wipe is why every stage here is additive), and
/// what keeps the ring's cursor reads and writes byte-for-byte what they were. Another device's key
/// carries its id as a suffix, so it can never collide with the ring's under the unique index, and
/// an `hk:` / `export:` name keeps its prefix, so every prefix filter keeps working.
public enum SyncCursorKey {
    static let separator = "@"

    public static func key(_ name: String, device: SyncDeviceID) -> String {
        device == .ringConn ? name : name + separator + device.rawValue
    }

    /// The cursor name a key of `device` carries, or nil when the key is not one of `device`'s.
    public static func name(fromKey key: String, device: SyncDeviceID) -> String? {
        guard device != .ringConn else { return key }
        let suffix = separator + device.rawValue
        guard key.hasSuffix(suffix), key.count > suffix.count else { return nil }
        return String(key.dropLast(suffix.count))
    }
}

extension SyncCursor {
    /// One device's cursor, from persisted `(key, device, last)` rows. Rows of other devices are
    /// ignored — that isolation is the whole fix: a new device's older backfill is judged against its
    /// OWN watermark. With only the ring present this is exactly the map the store built before.
    public static func forDevice(_ device: SyncDeviceID,
                                 rows: [(key: String, device: String, last: Date)]) -> SyncCursor {
        var map: [String: Date] = [:]
        for row in rows where row.device == device.rawValue {
            guard let name = SyncCursorKey.name(fromKey: row.key, device: device) else { continue }
            map[name] = row.last
        }
        return SyncCursor(lastByKind: map)
    }
}
