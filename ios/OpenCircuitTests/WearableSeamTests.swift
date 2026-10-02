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

    /// An `ActiveWearable` over a ring-only install (empty ownership log) whose ring fallback is
    /// `fallback`, the id the production resolvers fall back to (review-224b N-1).
    private func wearable(_ session: @escaping @MainActor () -> (any WearableSession)?, fallback: String?,
                          store: WearableIdentityStore) -> ActiveWearable {
        ActiveWearable(session: session, fallbackDeviceID: { fallback }, identityStore: store,
                       ringFallbackID: { fallback }, strapFallbackID: { nil }, ownership: { DeviceOwnershipLog() })
    }

    /// The `HKDevice` a ring write names, through BOTH resolvers every Health write calls (review-224b
    /// N-1): `wearableDevice(forTimeline:)` for tagged rows and `wearableDevice(ownerAt:)` for untagged
    /// ones. For a ring they must agree.
    private func healthDevice(_ active: ActiveWearable, file: StaticString = #filePath, line: UInt = #line) -> HKDevice? {
        let tagged = HealthKitWriter.wearableDevice(forTimeline: .ringConn, wearable: active)
        let untagged = HealthKitWriter.wearableDevice(ownerAt: Date(timeIntervalSince1970: 1_790_000_000), wearable: active)
        XCTAssertEqual(fields(tagged), fields(untagged), "both resolvers name the same device", file: file, line: line)
        return tagged
    }

    private func fields(_ device: HKDevice?) -> [String?] {
        device.map { [$0.name, $0.manufacturer, $0.model, $0.hardwareVersion, $0.firmwareVersion, $0.localIdentifier] } ?? []
    }

    private func device(of identity: WearableIdentity) -> HKDevice? {
        HealthKitWriter.hkDevice(HealthDeviceAttribution.fields(for: identity, origin: .device))
    }

    func testNoSessionAndNoHistoryMeansNoDevice() {
        let active = wearable({ nil }, fallback: nil, store: WearableIdentityStore(defaults))
        XCTAssertNil(active.session)
        XCTAssertEqual(active.capabilities, [])
        XCTAssertNil(healthDevice(active))
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
        let active = wearable({ current }, fallback: nil, store: store)
        XCTAssertEqual(healthDevice(active)?.firmwareVersion, "FR02.018")

        current = FakeWearable(identity: ring(firmware: FirmwareInfo(modelName: "RingConn Gen2-03AD")))
        XCTAssertEqual(fields(healthDevice(active)), fields(device(of: ring(firmware: fullFirmware))))
        XCTAssertEqual(store.load(id: ringID), ring(firmware: fullFirmware))
    }

    /// With nothing connected (a cold background flush, a ring out of range), writes still name
    /// the ring they came from — the persisted identity of the fallback id.
    func testDisconnectedWritesUseThePersistedIdentity() {
        let store = WearableIdentityStore(defaults)
        let connected = FakeWearable(identity: ring(firmware: fullFirmware))
        _ = healthDevice(wearable({ connected }, fallback: nil, store: store))

        let disconnected = wearable({ nil }, fallback: ringID, store: store)
        XCTAssertEqual(fields(healthDevice(disconnected)), fields(device(of: ring(firmware: fullFirmware))))

        let unknownRing = wearable({ nil }, fallback: "NEVER-SEEN", store: store)
        XCTAssertNil(healthDevice(unknownRing))
    }

    /// Switching rings never reports one ring's firmware under the other's id.
    func testASecondRingDoesNotInheritTheFirstRingsFields() {
        let store = WearableIdentityStore(defaults)
        let ringA = FakeWearable(identity: ring(firmware: fullFirmware))
        _ = healthDevice(wearable({ ringA }, fallback: nil, store: store))

        let ringB = FakeWearable(identity: ring(firmware: FirmwareInfo(modelName: "RingConn Gen2-11FF"),
                                                id: "OTHER-RING"))
        let active = wearable({ ringB }, fallback: nil, store: store)
        XCTAssertNil(healthDevice(active), "ring B hasn't identified itself and must not borrow A's fields")
        XCTAssertNil(store.load(id: "OTHER-RING"))

        ringB.identity = ring(firmware: FirmwareInfo(version: "FR02.020", modelName: "RingConn Gen2-11FF"),
                              id: "OTHER-RING")
        let named = healthDevice(active)
        XCTAssertEqual(store.load(id: "OTHER-RING")?.id, "OTHER-RING")
        XCTAssertEqual(named?.firmwareVersion, "FR02.020")
        XCTAssertNil(named?.hardwareVersion, "never ring A's hardware version")
    }

    /// Review #217 N1 (the reviewer's probe, now asserting the fix). On a ring's first connection
    /// nothing is persisted, and a flush can land before the DIS firmware read. That write must name
    /// NO device — exactly as before the seam — rather than a sparser one than every later write,
    /// which Apple Health would list as a second device.
    func testAWriteBeforeTheRingHasIdentifiedItselfNamesNoDevice() throws {
        let store = WearableIdentityStore(defaults)
        let fake = FakeWearable(identity: ring(firmware: FirmwareInfo(modelName: "RingConn Gen2-03AD")))
        let active = wearable({ fake }, fallback: nil, store: store)
        XCTAssertNil(healthDevice(active))
        XCTAssertNil(store.load(id: ringID), "a sparse identity is never recorded")
        XCTAssertNil(healthDevice(wearable({ nil }, fallback: ringID, store: store)),
                     "nor does a disconnected flush find one")

        fake.identity = ring(firmware: fullFirmware)   // the DIS reads landed
        let identified = try XCTUnwrap(healthDevice(active))
        XCTAssertEqual(identified.model, "Gen 2")
        XCTAssertEqual(identified.hardwareVersion, "00010001")
        XCTAssertEqual(identified.firmwareVersion, "FR02.018")

        // From here on every write names that same device, even one before a reconnect's DIS reads.
        fake.identity = ring(firmware: FirmwareInfo(modelName: "RingConn Gen2-03AD"))
        XCTAssertEqual(fields(healthDevice(active)), fields(identified))
        XCTAssertEqual(fields(healthDevice(wearable({ nil }, fallback: ringID, store: store))), fields(identified))
    }

    /// Review #217 S1 (Juan's decision): two RingConn rings are ONE device in Apple Health — the
    /// same `localIdentifier`, "ringconn" — while the identity store stays keyed per peripheral, so
    /// each ring keeps reporting its own firmware and neither inherits the other's.
    func testTwoRingsAreOneHealthDeviceButEachKeepsItsOwnFirmware() throws {
        let store = WearableIdentityStore(defaults)
        let ringA = FakeWearable(identity: ring(firmware: fullFirmware))
        let deviceA = try XCTUnwrap(healthDevice(wearable({ ringA }, fallback: nil, store: store)))
        let gen3 = FirmwareInfo(version: "FR05.011", modelName: "RingConn Gen3-11FF", hardwareRevision: "00030002")
        let ringB = FakeWearable(identity: ring(firmware: gen3, id: "OTHER-RING"))
        let deviceB = try XCTUnwrap(healthDevice(wearable({ ringB }, fallback: nil, store: store)))

        XCTAssertEqual(deviceA.localIdentifier, "ringconn")
        XCTAssertEqual(deviceB.localIdentifier, deviceA.localIdentifier)
        XCTAssertEqual(deviceA.firmwareVersion, "FR02.018")
        XCTAssertEqual(deviceB.firmwareVersion, "FR05.011")
        XCTAssertEqual(deviceB.hardwareVersion, "00030002")

        // Still two records, one per peripheral.
        XCTAssertEqual(store.load(id: ringID)?.firmwareVersion, "FR02.018")
        XCTAssertEqual(store.load(id: "OTHER-RING")?.firmwareVersion, "FR05.011")
        // A disconnected flush attributed to ring A names ring A's firmware, not B's.
        XCTAssertEqual(healthDevice(wearable({ nil }, fallback: ringID, store: store))?.firmwareVersion, "FR02.018")
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
