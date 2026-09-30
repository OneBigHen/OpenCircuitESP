import HealthKit
import Observation
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// The device seam (#214, docs/DEVICE_SEAM.md): `ActiveWearable`, and `HKDevice` attribution on
/// Health writes. All identities are synthetic.
@MainActor
final class WearableSeamTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "test.WearableSeamTests"
    private let ringID = "5B1E4C2A-0000-4000-8000-00000000A11C"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A stand-in wearable: the protocol is the whole contract `ActiveWearable` relies on.
    @Observable
    final class FakeWearable: WearableSession {
        var identity: WearableIdentity
        init(identity: WearableIdentity) { self.identity = identity }
        var deviceKind: WearableDeviceKind { identity.kind }
        var capabilities: WearableCapabilities = [.liveHeartRate, .historySync]
        var ready = true
        var isLinkConnected = true
        var lastFrameAt: Date?
        var batteryPercent: Int? = 80
        var charging = false
        var liveHR: Int?
        var liveHRAt: Date?
        var steps: Int?
        var syncing = false
        var syncStatus: String?
        func syncHistory(manual: Bool) {}
    }

    private func ring(firmware: FirmwareInfo, id: String? = nil) -> WearableIdentity {
        WearableIdentity.ringConn(id: id ?? ringID,
                                  modelFamily: RingMetadataStore.modelFamily(firmware.modelName),
                                  firmware: firmware)
    }

    private let fullFirmware = FirmwareInfo(version: "FR02.018", modelName: "RingConn Gen2-03AD",
                                            manufacturer: "JZ_Tech", hardwareRevision: "00010001",
                                            mac: "F8:79:99:00:03:AD")

    // MARK: Identity (the RingSession conformance's recipe)

    /// The advertised name carries two MAC bytes; the identity — and so Apple Health — must not.
    func testRingIdentityStripsTheAdvertisedMACSuffix() {
        let identity = ring(firmware: fullFirmware)
        XCTAssertEqual(identity.name, "RingConn Gen2")
        XCTAssertEqual(identity.displayName, "RingConn Gen2")
        let fields = HealthDeviceAttribution.fields(for: identity, origin: .device)
        XCTAssertFalse([fields?.name, fields?.model, fields?.hardwareVersion, fields?.firmwareVersion,
                        fields?.localIdentifier].compactMap { $0 }.contains { $0.uppercased().contains("03AD") })
    }

    // MARK: ActiveWearable

    func testNoSessionAndNoHistoryMeansNoDevice() {
        let active = ActiveWearable(session: { nil }, fallbackDeviceID: { nil },
                                    identityStore: WearableIdentityStore(defaults))
        XCTAssertNil(active.session)
        XCTAssertEqual(active.capabilities, [])
        XCTAssertNil(active.identityForHealthWrite())
    }

    func testCapabilitiesComeFromTheActiveSession() {
        let fake = FakeWearable(identity: ring(firmware: fullFirmware))
        let active = ActiveWearable(session: { fake }, fallbackDeviceID: { nil },
                                    identityStore: WearableIdentityStore(defaults))
        XCTAssertEqual(active.capabilities, [.liveHeartRate, .historySync])
    }

    /// A fresh session before the DIS reads land must still name the ring with everything we
    /// learned about it before — otherwise Apple Health lists one ring as several devices.
    func testIdentityIsMergedWithWhatWasKnownForTheSameRing() {
        let store = WearableIdentityStore(defaults)
        var current = FakeWearable(identity: ring(firmware: fullFirmware))
        let active = ActiveWearable(session: { current }, fallbackDeviceID: { nil }, identityStore: store)
        XCTAssertEqual(active.identityForHealthWrite()?.firmwareVersion, "FR02.018")

        current = FakeWearable(identity: ring(firmware: FirmwareInfo(modelName: "RingConn Gen2-03AD")))
        let merged = active.identityForHealthWrite()
        XCTAssertEqual(merged, ring(firmware: fullFirmware))
    }

    /// With nothing connected (a cold background flush, a ring out of range), writes still name
    /// the ring they came from — the persisted identity of the fallback id.
    func testDisconnectedWritesUseThePersistedIdentity() {
        let store = WearableIdentityStore(defaults)
        let connected = FakeWearable(identity: ring(firmware: fullFirmware))
        _ = ActiveWearable(session: { connected }, fallbackDeviceID: { nil }, identityStore: store)
            .identityForHealthWrite()

        let disconnected = ActiveWearable(session: { nil }, fallbackDeviceID: { self.ringID },
                                          identityStore: store)
        XCTAssertEqual(disconnected.identityForHealthWrite(), ring(firmware: fullFirmware))

        let unknownRing = ActiveWearable(session: { nil }, fallbackDeviceID: { "NEVER-SEEN" },
                                         identityStore: store)
        XCTAssertNil(unknownRing.identityForHealthWrite())
    }

    /// Switching rings never reports one ring's firmware under the other's id.
    func testASecondRingDoesNotInheritTheFirstRingsFields() {
        let store = WearableIdentityStore(defaults)
        let ringA = FakeWearable(identity: ring(firmware: fullFirmware))
        _ = ActiveWearable(session: { ringA }, fallbackDeviceID: { nil }, identityStore: store)
            .identityForHealthWrite()

        let ringB = FakeWearable(identity: ring(firmware: FirmwareInfo(modelName: "RingConn Gen2-11FF"),
                                                id: "OTHER-RING"))
        let identity = ActiveWearable(session: { ringB }, fallbackDeviceID: { nil }, identityStore: store)
            .identityForHealthWrite()
        XCTAssertEqual(identity?.id, "OTHER-RING")
        XCTAssertNil(identity?.firmwareVersion)
        XCTAssertNil(identity?.hardwareVersion)
    }

    /// Review #217 S1 (Juan's decision): two RingConn rings are ONE device in Apple Health — the
    /// same `localIdentifier`, "ringconn" — while the identity store stays keyed per peripheral, so
    /// each ring keeps reporting its own firmware and neither inherits the other's.
    func testTwoRingsAreOneHealthDeviceButEachKeepsItsOwnFirmware() throws {
        let store = WearableIdentityStore(defaults)
        let ringA = FakeWearable(identity: ring(firmware: fullFirmware))
        let a = try XCTUnwrap(ActiveWearable(session: { ringA }, fallbackDeviceID: { nil }, identityStore: store)
            .identityForHealthWrite())
        let gen3 = FirmwareInfo(version: "FR05.011", modelName: "RingConn Gen3-11FF", hardwareRevision: "00030002")
        let ringB = FakeWearable(identity: ring(firmware: gen3, id: "OTHER-RING"))
        let b = try XCTUnwrap(ActiveWearable(session: { ringB }, fallbackDeviceID: { nil }, identityStore: store)
            .identityForHealthWrite())

        let deviceA = try XCTUnwrap(HealthKitWriter.hkDevice(HealthDeviceAttribution.fields(for: a, origin: .device)))
        let deviceB = try XCTUnwrap(HealthKitWriter.hkDevice(HealthDeviceAttribution.fields(for: b, origin: .device)))
        XCTAssertEqual(deviceA.localIdentifier, "ringconn")
        XCTAssertEqual(deviceB.localIdentifier, deviceA.localIdentifier)
        XCTAssertEqual(deviceA.firmwareVersion, "FR02.018")
        XCTAssertEqual(deviceB.firmwareVersion, "FR05.011")
        XCTAssertEqual(deviceB.hardwareVersion, "00030002")

        // Still two records, one per peripheral.
        XCTAssertEqual(store.load(id: ringID)?.firmwareVersion, "FR02.018")
        XCTAssertEqual(store.load(id: "OTHER-RING")?.firmwareVersion, "FR05.011")
        // A disconnected flush attributed to ring A names ring A's firmware, not B's.
        XCTAssertEqual(ActiveWearable(session: { nil }, fallbackDeviceID: { self.ringID }, identityStore: store)
            .identityForHealthWrite()?.firmwareVersion, "FR02.018")
    }

    // MARK: HKDevice

    func testHKDeviceCarriesEveryMappedField() throws {
        let fields = try XCTUnwrap(HealthDeviceAttribution.fields(for: ring(firmware: fullFirmware),
                                                                  origin: .device))
        let device = try XCTUnwrap(HealthKitWriter.hkDevice(fields))
        XCTAssertEqual(device.name, "RingConn Gen2")
        XCTAssertEqual(device.manufacturer, "RingConn")
        XCTAssertEqual(device.model, "Gen 2")
        XCTAssertEqual(device.hardwareVersion, "00010001")
        XCTAssertEqual(device.firmwareVersion, "FR02.018")
        XCTAssertNil(device.softwareVersion)
        XCTAssertEqual(device.localIdentifier, "ringconn", "every RingConn ring is one Health device")
        XCTAssertNil(device.udiDeviceIdentifier)
        XCTAssertNil(HealthKitWriter.hkDevice(nil))
    }

    func testActiveEnergySampleCarriesTheDevice() throws {
        let fields = HealthDeviceAttribution.fields(for: ring(firmware: fullFirmware), origin: .device)
        let device = HealthKitWriter.hkDevice(fields)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let sample = try XCTUnwrap(HealthKitWriter.activeEnergySample(
            kcal: 12, start: start, end: start.addingTimeInterval(900), device: device))
        XCTAssertEqual(sample.device?.localIdentifier, "ringconn")
        XCTAssertEqual(sample.device?.firmwareVersion, "FR02.018")
    }

    /// Measured sleep names the ring; a span the wearer asserted (and a typed nap) names no device —
    /// the ring did not record it. The user-entered tag itself is unchanged.
    func testSleepNamesTheDeviceOnMeasuredSpansOnly() throws {
        let device = HealthKitWriter.hkDevice(
            HealthDeviceAttribution.fields(for: ring(firmware: fullFirmware), origin: .device))
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let night = [
            SleepSegment(start: t0, end: t0.addingTimeInterval(3600), stage: .asleepCore),
            SleepSegment(start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(7200),
                         stage: .asleepCore, provenance: .asserted),
        ]
        let samples = HealthKitWriter.sleepSamples(night, device: device, site: "test")
        XCTAssertEqual(samples.count, 2)
        let measured = try XCTUnwrap(samples.first { $0.startDate == t0 })
        let asserted = try XCTUnwrap(samples.first { $0.startDate != t0 })
        XCTAssertEqual(measured.device?.localIdentifier, "ringconn")
        XCTAssertNil(measured.metadata?[HKMetadataKeyWasUserEntered])
        XCTAssertNil(asserted.device)
        XCTAssertEqual(asserted.metadata?[HKMetadataKeyWasUserEntered] as? Bool, true)

        let typedNap = HealthKitWriter.sleepSamples(night, allUserEntered: true, device: device, site: "test")
        XCTAssertEqual(typedNap.count, 2)
        XCTAssertTrue(typedNap.allSatisfy { $0.device == nil })
    }
}
