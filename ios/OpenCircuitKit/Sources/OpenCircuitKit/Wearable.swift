// The device-agnostic description of "a wearable" — the value half of the device seam (#214,
// docs/DEVICE_SEAM.md). The app's `WearableSession` protocol hands these out; nothing here knows
// about CoreBluetooth, HealthKit or SwiftData, so every rule below is covered by `swift test`.
//
// v1 has ONE active device at a time. A RingConn ring is the only driver today; the Zepp OS
// (Amazfit Helio) driver arrives in its own PR and only has to produce these same values.

import Foundation

extension RingGeneration: Codable {}

// MARK: - Kind

/// Which family of device a session drives, and which model within it.
public enum WearableDeviceKind: Hashable, Sendable, Codable {
    /// A RingConn ring. `.unknown` until the DIS firmware-revision read lands (`FirmwareInfo`).
    case ringConn(model: RingGeneration)
    /// A Zepp OS device (Amazfit Helio Strap / Ring). The model string is whatever the Zepp driver
    /// identifies; empty means not identified yet.
    case zeppOS(model: String)

    /// The brand a person recognises, used as the Health `manufacturer`. Not the DIS manufacturer
    /// string: a RingConn ring reports its OEM there (`JZ_Tech`, PROTOCOL.md §1).
    public var brand: String {
        switch self {
        case .ringConn: return "RingConn"
        case .zeppOS: return "Amazfit"
        }
    }

    /// Human-readable model label, or nil while the model is not identified. Never a placeholder
    /// such as "Unknown" — a consumer that prints this must not print a guess.
    public var modelLabel: String? {
        switch self {
        case .ringConn(let generation):
            return generation == .unknown ? nil : generation.rawValue
        case .zeppOS(let model):
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Capabilities

/// What a connected wearable can do. The UI gates device-specific CONTROLS on these; data that is
/// simply shown when present (a charging-case battery, a live skin temperature reading) gates on
/// the data instead and needs no capability.
public struct WearableCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let liveHeartRate             = WearableCapabilities(rawValue: 1 << 0)
    public static let historySync               = WearableCapabilities(rawValue: 1 << 1)
    public static let battery                   = WearableCapabilities(rawValue: 1 << 2)
    public static let vibration                 = WearableCapabilities(rawValue: 1 << 3)
    public static let findMyDevice              = WearableCapabilities(rawValue: 1 << 4)
    public static let alarm                     = WearableCapabilities(rawValue: 1 << 5)
    public static let bloodPressureCalibration  = WearableCapabilities(rawValue: 1 << 6)
    public static let onDemandHeartRate         = WearableCapabilities(rawValue: 1 << 7)
    public static let onDemandSpO2              = WearableCapabilities(rawValue: 1 << 8)
    public static let skinTemperature           = WearableCapabilities(rawValue: 1 << 9)
    /// Turn the device's radio off (RingConn `#96`; it only comes back in the charging case).
    public static let airplaneMode              = WearableCapabilities(rawValue: 1 << 10)
    /// Arm a dense overnight SpO₂ recording for the sleep-apnea estimate (#91).
    public static let sleepApneaAssessment      = WearableCapabilities(rawValue: 1 << 11)
    /// The device detects and buffers workouts on its own (RingConn automatic workout detection).
    public static let automaticWorkoutDetection = WearableCapabilities(rawValue: 1 << 12)
    /// A native workout mode with its own HR/steps stream (RingConn sport mode, `0x4e`).
    public static let nativeWorkoutMode         = WearableCapabilities(rawValue: 1 << 13)
    /// Raw-frame diagnostics capture, repair import and the reverse-engineering probes.
    public static let diagnosticsCapture        = WearableCapabilities(rawValue: 1 << 14)

    /// A RingConn ring's capabilities. Mirrors the gates the UI already applies, so a view that
    /// switches to checking a capability behaves exactly as before:
    ///   • vibration + alarm — Gen 3 only (`RingVibration.isSupported`). Fails CLOSED: nothing
    ///     while the generation is unknown.
    ///   • sleep-apnea arming — withheld only from a POSITIVELY identified Gen 2 Air (#186). Fails
    ///     OPEN, like `DeviceInfoView.sleepApneaUnavailable`.
    public static func ringConn(generation: RingGeneration) -> WearableCapabilities {
        var caps: WearableCapabilities = [
            .liveHeartRate, .historySync, .battery, .findMyDevice, .bloodPressureCalibration,
            .onDemandHeartRate, .onDemandSpO2, .skinTemperature, .airplaneMode,
            .automaticWorkoutDetection, .nativeWorkoutMode, .diagnosticsCapture,
        ]
        if RingVibration.isSupported(generation) { caps.formUnion([.vibration, .alarm]) }
        if generation != .gen2Air { caps.insert(.sleepApneaAssessment) }
        return caps
    }
}

// MARK: - Identity

/// Who a wearable is. Feeds Apple Health's `HKDevice` (see `HealthDeviceAttribution`).
///
/// PRIVACY: no field may carry a MAC or any byte derived from one. `id` is a per-install
/// identifier (CoreBluetooth's peripheral UUID for a BLE device) and `name` must already have any
/// MAC suffix removed by the caller (RingConn's advertised name ends in two MAC bytes).
public struct WearableIdentity: Hashable, Sendable, Codable {
    /// Stable per-device id. The key everything per-device is scoped by.
    public var id: String
    public var kind: WearableDeviceKind
    /// Model family ("RingConn Gen2"), or nil when the device gave no name.
    public var name: String?
    public var hardwareVersion: String?
    public var firmwareVersion: String?

    public init(id: String, kind: WearableDeviceKind, name: String? = nil,
                hardwareVersion: String? = nil, firmwareVersion: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = Self.clean(name)
        self.hardwareVersion = Self.clean(hardwareVersion)
        self.firmwareVersion = Self.clean(firmwareVersion)
    }

    public var manufacturer: String { kind.brand }
    public var model: String? { kind.modelLabel }
    /// What to call the device on screen or in Health: its name, else its brand. Never empty.
    public var displayName: String { name ?? manufacturer }

    /// A RingConn ring's identity from what the ring told us. `modelFamily` must be the advertised
    /// name with its MAC suffix already stripped (`RingMetadataStore.modelFamily` in the app).
    public static func ringConn(id: String, modelFamily: String,
                                firmware: FirmwareInfo) -> WearableIdentity {
        WearableIdentity(id: id, kind: .ringConn(model: firmware.generation), name: modelFamily,
                         hardwareVersion: firmware.hardwareRevision,
                         firmwareVersion: firmware.version)
    }

    /// This identity with any field it doesn't know filled from `previous` — but ONLY when
    /// `previous` is the same device. Device fields arrive one GATT read at a time and are gone
    /// while disconnected, so without this one device would be written to Health under several
    /// partially-filled identities. A different `id` never inherits anything: one device's
    /// firmware must not be reported under another's (the rule `RingMetadataStore.record` uses).
    public func merging(previous: WearableIdentity?) -> WearableIdentity {
        guard let previous, previous.id == id else { return self }
        var merged = self
        if merged.kind.modelLabel == nil, previous.kind.modelLabel != nil,
           merged.kind.sameFamily(as: previous.kind) {
            merged.kind = previous.kind
        }
        merged.name = name ?? previous.name
        merged.hardwareVersion = hardwareVersion ?? previous.hardwareVersion
        merged.firmwareVersion = firmwareVersion ?? previous.firmwareVersion
        return merged
    }

    /// nil for nil, empty or whitespace-only — so no field is ever written out as "".
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension WearableDeviceKind {
    func sameFamily(as other: WearableDeviceKind) -> Bool {
        switch (self, other) {
        case (.ringConn, .ringConn), (.zeppOS, .zeppOS): return true
        default: return false
        }
    }
}

// MARK: - Apple Health attribution

/// The fields of an `HKDevice`, as plain values. The app turns this into an `HKDevice` one-to-one;
/// keeping the mapping here is what lets it be tested without HealthKit.
public struct HealthDeviceFields: Equatable, Sendable {
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var hardwareVersion: String?
    public var firmwareVersion: String?
    public var softwareVersion: String?
    public var localIdentifier: String?
    public var udiDeviceIdentifier: String?
}

public enum HealthDeviceAttribution {
    /// Where a Health sample's value came from.
    public enum Origin: Sendable {
        /// Measured by the wearable, or derived from what it measured (energy, resting HR, a BP
        /// estimate from its PPG).
        case device
        /// Typed or asserted by the person (a headache or period log, an asserted sleep span, a
        /// manually added nap) — the samples written with `HKMetadataKeyWasUserEntered: true`.
        case userEntered
    }

    /// The `HKDevice` fields for a sample, or nil when the sample must not name a device: no
    /// wearable is known, or the person entered the value. Naming the ring on a headache the user
    /// logged would state that the ring measured it.
    public static func fields(for identity: WearableIdentity?, origin: Origin) -> HealthDeviceFields? {
        guard let identity, origin == .device else { return nil }
        return HealthDeviceFields(name: identity.displayName,
                                  manufacturer: identity.manufacturer,
                                  model: identity.model,
                                  hardwareVersion: identity.hardwareVersion,
                                  firmwareVersion: identity.firmwareVersion,
                                  softwareVersion: nil,
                                  localIdentifier: localIdentifier(for: identity),
                                  udiDeviceIdentifier: nil)
    }

    /// A device family's `HKDevice.localIdentifier` is its sync timeline id
    /// (`SyncDeviceID.timeline(for:identityID:)`), so Apple Health names the same device the store
    /// keys by. Every RingConn ring is therefore "ringconn" — multi-ring is one merged timeline, so
    /// a backlog flushed after a ring swap can't be labelled with the wrong ring's id. A Zepp OS
    /// device gets its own `zeppos:<id>`. Only the id is shared: name and versions still come from
    /// the identity, which `ActiveWearable` persists per peripheral. nil when the identity has no id.
    static func localIdentifier(for identity: WearableIdentity) -> String? {
        WearableIdentity.clean(identity.id).map {
            SyncDeviceID.timeline(for: identity.kind, identityID: $0).rawValue
        }
    }
}
