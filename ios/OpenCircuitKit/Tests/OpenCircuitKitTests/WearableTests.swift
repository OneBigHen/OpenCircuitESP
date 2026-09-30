import XCTest
@testable import OpenCircuitKit

/// The value half of the device seam (#214, docs/DEVICE_SEAM.md). All fixtures are synthetic.
final class WearableTests: XCTestCase {

    private let ringID = "5B1E4C2A-0000-4000-8000-00000000A11C"

    private func firmware(_ version: String, hardware: String? = "00010001") -> FirmwareInfo {
        FirmwareInfo(version: version, modelName: "RingConn Gen2-03AD", manufacturer: "JZ_Tech",
                     hardwareRevision: hardware, mac: "F8:79:99:00:03:AD")
    }

    // MARK: Kind

    func testKindBrandAndModelLabel() {
        XCTAssertEqual(WearableDeviceKind.ringConn(model: .gen3).brand, "RingConn")
        XCTAssertEqual(WearableDeviceKind.ringConn(model: .gen3).modelLabel, "Gen 3")
        XCTAssertEqual(WearableDeviceKind.ringConn(model: .gen2Air).modelLabel, "Gen 2 Air")
        XCTAssertEqual(WearableDeviceKind.zeppOS(model: "Helio Strap").brand, "Amazfit")
        XCTAssertEqual(WearableDeviceKind.zeppOS(model: " Helio Strap ").modelLabel, "Helio Strap")
    }

    /// An unidentified model is nil, never the literal "Unknown" — Health must not show a guess.
    func testUnidentifiedModelIsNilNotAPlaceholder() {
        XCTAssertNil(WearableDeviceKind.ringConn(model: .unknown).modelLabel)
        XCTAssertNil(WearableDeviceKind.zeppOS(model: "  ").modelLabel)
    }

    // MARK: Capabilities

    func testBriefMinimumCapabilitiesAreDistinct() {
        let all: [WearableCapabilities] = [
            .liveHeartRate, .historySync, .battery, .vibration, .findMyDevice, .alarm,
            .bloodPressureCalibration, .onDemandHeartRate, .onDemandSpO2, .skinTemperature,
            .airplaneMode, .sleepApneaAssessment, .automaticWorkoutDetection, .nativeWorkoutMode,
            .diagnosticsCapture,
        ]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count, "two capabilities share a bit")
    }

    /// Vibration + alarm follow `RingVibration.isSupported` exactly, for every generation — the
    /// gate `DeviceInfoView` applies today, so switching it to the capability changes nothing.
    func testRingVibrationAndAlarmMirrorTheExistingGate() {
        for generation in [RingGeneration.gen1, .gen2, .gen2Air, .gen3, .unknown] {
            let caps = WearableCapabilities.ringConn(generation: generation)
            let supported = RingVibration.isSupported(generation)
            XCTAssertEqual(caps.contains(.vibration), supported, "\(generation)")
            XCTAssertEqual(caps.contains(.alarm), supported, "\(generation)")
        }
        XCTAssertFalse(WearableCapabilities.ringConn(generation: .unknown).contains(.vibration),
                       "vibration must fail CLOSED before the DIS read lands")
    }

    /// Sleep-apnea arming is withheld from a positively identified Gen 2 Air only (#186) and fails
    /// OPEN while the generation is unknown — the same rule as `DeviceInfoView.sleepApneaUnavailable`.
    func testRingSleepApneaMirrorsTheExistingGate() {
        XCTAssertFalse(WearableCapabilities.ringConn(generation: .gen2Air).contains(.sleepApneaAssessment))
        for generation in [RingGeneration.gen1, .gen2, .gen3, .unknown] {
            XCTAssertTrue(WearableCapabilities.ringConn(generation: generation).contains(.sleepApneaAssessment),
                          "\(generation)")
        }
    }

    func testEveryRingHasTheCoreCapabilities() {
        let core: WearableCapabilities = [
            .liveHeartRate, .historySync, .battery, .findMyDevice, .bloodPressureCalibration,
            .onDemandHeartRate, .onDemandSpO2, .skinTemperature, .airplaneMode,
            .automaticWorkoutDetection, .nativeWorkoutMode, .diagnosticsCapture,
        ]
        for generation in [RingGeneration.gen1, .gen2, .gen2Air, .gen3, .unknown] {
            XCTAssertTrue(WearableCapabilities.ringConn(generation: generation).isSuperset(of: core),
                          "\(generation)")
        }
    }

    // MARK: Identity

    func testRingIdentityFromFirmwareInfo() {
        let identity = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                                 firmware: firmware("FR02.018"))
        XCTAssertEqual(identity.id, ringID)
        XCTAssertEqual(identity.kind, .ringConn(model: .gen2))
        XCTAssertEqual(identity.displayName, "RingConn Gen2")
        XCTAssertEqual(identity.manufacturer, "RingConn", "the brand, not the DIS OEM string")
        XCTAssertEqual(identity.model, "Gen 2")
        XCTAssertEqual(identity.hardwareVersion, "00010001")
        XCTAssertEqual(identity.firmwareVersion, "FR02.018")
    }

    /// Before the DIS reads land every optional field is nil — not "" and not a guess — and the
    /// display name falls back to the brand, so it is never empty.
    func testRingIdentityBeforeDISReadsIsHonestlyEmpty() {
        let identity = WearableIdentity.ringConn(id: ringID, modelFamily: "",
                                                 firmware: FirmwareInfo())
        XCTAssertNil(identity.name)
        XCTAssertNil(identity.model)
        XCTAssertNil(identity.hardwareVersion)
        XCTAssertNil(identity.firmwareVersion)
        XCTAssertEqual(identity.displayName, "RingConn")
    }

    /// The identity carries none of `FirmwareInfo`'s MAC — not in any field.
    func testRingIdentityNeverCarriesTheMAC() throws {
        let identity = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                                 firmware: firmware("FR05.011"))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(identity), encoding: .utf8))
        XCTAssertFalse(encoded.contains("F8:79"), encoded)
        XCTAssertFalse(encoded.uppercased().contains("03AD"), encoded)
    }

    // MARK: Merge

    func testMergeFillsUnknownFieldsFromTheSameDevice() {
        let known = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                              firmware: firmware("FR02.018"))
        // A cold relaunch before the DIS reads land: same ring, nothing read yet.
        let fresh = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                              firmware: FirmwareInfo())
        XCTAssertEqual(fresh.merging(previous: known), known)
    }

    func testMergePrefersWhatTheDeviceSaysNow() {
        let old = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                            firmware: firmware("FR02.018"))
        let updated = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                                firmware: firmware("FR02.020"))
        XCTAssertEqual(updated.merging(previous: old).firmwareVersion, "FR02.020")
    }

    /// A different device inherits NOTHING — one ring's firmware must never be reported under
    /// another ring's id.
    func testMergeNeverCrossesDevices() {
        let ringA = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                              firmware: firmware("FR02.018"))
        let ringB = WearableIdentity.ringConn(id: "OTHER-RING", modelFamily: "",
                                              firmware: FirmwareInfo())
        XCTAssertEqual(ringB.merging(previous: ringA), ringB)
        XCTAssertEqual(ringB.merging(previous: nil), ringB)
    }

    func testMergeNeverTurnsARingIntoAnotherFamily() {
        let strap = WearableIdentity(id: ringID, kind: .zeppOS(model: "Helio Strap"))
        let ring = WearableIdentity(id: ringID, kind: .ringConn(model: .unknown))
        XCTAssertEqual(ring.merging(previous: strap).kind, .ringConn(model: .unknown))
    }

    func testIdentityRoundTripsThroughCodable() throws {
        for identity in [
            WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2", firmware: firmware("FR04.002")),
            WearableIdentity(id: "Z", kind: .zeppOS(model: "Helio Strap"), firmwareVersion: "3.0.1"),
        ] {
            let data = try JSONEncoder().encode(identity)
            XCTAssertEqual(try JSONDecoder().decode(WearableIdentity.self, from: data), identity)
        }
    }

    // MARK: HKDevice field mapping

    func testHealthDeviceFieldMapping() throws {
        let identity = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                                 firmware: firmware("FR02.018"))
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: identity, origin: .device))
        XCTAssertEqual(fields, HealthDeviceFields(name: "RingConn Gen2",
                                                  manufacturer: "RingConn",
                                                  model: "Gen 2",
                                                  hardwareVersion: "00010001",
                                                  firmwareVersion: "FR02.018",
                                                  softwareVersion: nil,
                                                  localIdentifier: "ringconn",
                                                  udiDeviceIdentifier: nil))
    }

    /// Juan's decision (review #217 S1): every RingConn ring is ONE device in Apple Health — the
    /// family's sync timeline id, the same "ringconn" the store keys every ring's rows by. Each ring
    /// still reports its own name and versions.
    func testEveryRingConnRingSharesOneLocalIdentifierButKeepsItsOwnFirmware() throws {
        let ringA = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                              firmware: firmware("FR02.018"))
        let ringB = WearableIdentity.ringConn(id: "0D4C1B7E-0000-4000-8000-00000000B0B0",
                                              modelFamily: "RingConn Gen3",
                                              firmware: FirmwareInfo(version: "FR05.011", hardwareRevision: "00030002"))
        let a = try XCTUnwrap(HealthDeviceAttribution.fields(for: ringA, origin: .device))
        let b = try XCTUnwrap(HealthDeviceAttribution.fields(for: ringB, origin: .device))
        XCTAssertEqual(a.localIdentifier, "ringconn")
        XCTAssertEqual(b.localIdentifier, a.localIdentifier)
        XCTAssertEqual(a.localIdentifier, SyncDeviceID.ringConn.rawValue)
        XCTAssertEqual(a.firmwareVersion, "FR02.018")
        XCTAssertEqual(b.firmwareVersion, "FR05.011")
        XCTAssertEqual(a.hardwareVersion, "00010001")
        XCTAssertEqual(b.hardwareVersion, "00030002")
        XCTAssertEqual(a.name, "RingConn Gen2")
        XCTAssertEqual(b.name, "RingConn Gen3")
    }

    /// The same rule with no special case: a Zepp OS device's id is its own timeline, `zeppos:<id>`,
    /// so two straps stay two devices and never collide with the ring.
    func testTheLocalIdentifierIsTheFamilysSyncTimelineForEveryFamily() throws {
        let strap = WearableIdentity(id: "STRAP-1", kind: .zeppOS(model: "Helio Strap"), firmwareVersion: "3.0.1")
        let other = WearableIdentity(id: "STRAP-2", kind: .zeppOS(model: "Helio Strap"))
        let s = try XCTUnwrap(HealthDeviceAttribution.fields(for: strap, origin: .device))
        let o = try XCTUnwrap(HealthDeviceAttribution.fields(for: other, origin: .device))
        XCTAssertEqual(s.localIdentifier, "zeppos:STRAP-1")
        XCTAssertEqual(o.localIdentifier, "zeppos:STRAP-2")
        for identity in [strap, other, WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                                                 firmware: firmware("FR02.018"))] {
            XCTAssertEqual(HealthDeviceAttribution.fields(for: identity, origin: .device)?.localIdentifier,
                           SyncDeviceID.timeline(for: identity.kind, identityID: identity.id).rawValue)
        }
        // No id, no identifier — never a bare "zeppos:".
        XCTAssertNil(HealthDeviceAttribution.fields(
            for: WearableIdentity(id: " ", kind: .zeppOS(model: "Helio Strap")), origin: .device)?.localIdentifier)
    }

    /// Unknown fields map to nil, never to "" — Health would show an empty row otherwise.
    func testHealthDeviceFieldsNeverCarryEmptyStrings() throws {
        let identity = WearableIdentity.ringConn(id: ringID, modelFamily: " ",
                                                 firmware: FirmwareInfo(version: "", hardwareRevision: ""))
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: identity, origin: .device))
        XCTAssertEqual(fields.name, "RingConn")
        XCTAssertNil(fields.model)
        XCTAssertNil(fields.hardwareVersion)
        XCTAssertNil(fields.firmwareVersion)
        XCTAssertEqual(fields.localIdentifier, "ringconn")
    }

    /// A value the person entered names no device, and no device known means no attribution —
    /// both exactly what every write did before the seam.
    func testNoAttributionForUserEnteredOrUnknownDevice() {
        let identity = WearableIdentity.ringConn(id: ringID, modelFamily: "RingConn Gen2",
                                                 firmware: firmware("FR02.018"))
        XCTAssertNil(HealthDeviceAttribution.fields(for: identity, origin: .userEntered))
        XCTAssertNil(HealthDeviceAttribution.fields(for: nil, origin: .device))
        XCTAssertNil(HealthDeviceAttribution.fields(for: nil, origin: .userEntered))
    }
}
