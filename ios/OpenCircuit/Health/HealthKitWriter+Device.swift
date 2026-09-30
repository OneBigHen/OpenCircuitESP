import Foundation
import HealthKit
import OpenCircuitKit

// `HKDevice` attribution (#214, docs/DEVICE_SEAM.md §2). Every sample the wearable measured, or that
// is derived from what it measured, names the active wearable. What the person entered names none.
// The field mapping is `HealthDeviceAttribution.fields(for:origin:)` in OpenCircuitKit (tested there);
// this file only turns those fields into an `HKDevice`, one-to-one.
extension HealthKitWriter {
    /// The `HKDevice` for `fields`, or nil when there is nothing to name — exactly what every write
    /// passed before the seam.
    static func hkDevice(_ fields: HealthDeviceFields?) -> HKDevice? {
        guard let fields else { return nil }
        return HKDevice(name: fields.name,
                        manufacturer: fields.manufacturer,
                        model: fields.model,
                        hardwareVersion: fields.hardwareVersion,
                        firmwareVersion: fields.firmwareVersion,
                        softwareVersion: fields.softwareVersion,
                        localIdentifier: fields.localIdentifier,
                        udiDeviceIdentifier: fields.udiDeviceIdentifier)
    }

    /// The `HKDevice` for rows on `timeline` (decision 28, #215: attribution follows the row, never
    /// the current choice). Resolved at write time, not when the writer is created: `ContentView`
    /// holds one writer from before the device connects.
    func wearableDevice(forTimeline timeline: SyncDeviceID) -> HKDevice? {
        Self.wearableDevice(forTimeline: timeline, wearable: .shared)
    }

    /// The `HKDevice` for an untagged row at `date`: the device that owned `date`. For a ring-only
    /// install, the connected (or last) ring.
    func wearableDevice(ownerAt date: Date) -> HKDevice? {
        Self.wearableDevice(ownerAt: date, wearable: .shared)
    }

    /// The two resolvers over an explicit `ActiveWearable`, so the first-write guard's tests (#222)
    /// exercise exactly what production writes call (review-224b N-1).
    static func wearableDevice(forTimeline timeline: SyncDeviceID, wearable: ActiveWearable) -> HKDevice? {
        hkDevice(HealthDeviceAttribution.fields(for: wearable.identityForHealthWrite(timeline: timeline), origin: .device))
    }

    static func wearableDevice(ownerAt date: Date, wearable: ActiveWearable) -> HKDevice? {
        hkDevice(HealthDeviceAttribution.fields(for: wearable.identityForHealthWrite(at: date), origin: .device))
    }

    /// Resolves owners once per family for a batch of untagged rows (a flush can carry thousands).
    @MainActor
    struct OwnerDeviceCache {
        private var cache: [DeviceOwnershipLog.Family: HKDevice?] = [:]
        private let log = LocalStore.ownershipLog()

        mutating func device(at date: Date, writer: HealthKitWriter) -> HKDevice? {
            let family = log.owner(at: date)
            if let hit = cache[family] { return hit }
            let resolved = writer.wearableDevice(ownerAt: date)
            cache[family] = resolved
            return resolved
        }
    }
}
