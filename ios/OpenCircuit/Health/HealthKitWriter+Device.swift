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

    /// The active wearable as an `HKDevice`, for a sample it measured. Resolved at write time, not
    /// when the writer is created: `ContentView` holds one writer from before the ring connects.
    func activeWearableDevice() -> HKDevice? {
        Self.hkDevice(HealthDeviceAttribution.fields(for: ActiveWearable.shared.identityForHealthWrite(),
                                                     origin: .device))
    }
}
