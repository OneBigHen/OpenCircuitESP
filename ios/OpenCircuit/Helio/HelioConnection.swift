import CoreBluetooth
import Foundation
import Observation
import OpenCircuitKit
import UIKit
import ZeppKit

// CoreBluetooth for the Amazfit Helio Strap (#215 phase 3). Thin glue, like HelioVerify: discovery,
// characteristic lookup by UUID across every service (ZEPP_PROTOCOL.md §2), notify toggles, and
// write-without-response flow control. Every protocol decision lives in `HelioSession` / ZeppKit.
//
// Its OWN central with its own restore identifier, so the ring's central (`RingScanner`) and this one
// never share state (decision 1: the inactive device is never scanned for or connected). Created
// lazily, like the ring's (#142), so merely constructing this object never prompts for Bluetooth.
// State restoration only re-adopts the strap's peripheral here; background syncing is Phase 4.

@Observable
@MainActor
final class HelioConnection: NSObject {
    static let shared = HelioConnection()

    /// Constant for the life of the app: iOS hands restored state back by this identifier.
    static let restoreIdentifier = "com.standardsoftwaresolutions.opencircuit.helio"
    /// The strap's CoreBluetooth identifier (per install, never its MAC).
    static let savedPeripheralKey = "helio.peripheralID.v1"
    /// How long a foreground search runs before it reports "not found".
    static let scanTimeout: TimeInterval = 20

    enum State: Equatable {
        case idle
        case bluetoothOff
        case bluetoothDenied
        case searching
        case notFound
        case connecting
        case connected
    }

    private(set) var state: State = .idle
    private(set) var session: HelioSession?
    /// The link's signal strength while the find screen polls it.
    private(set) var rssi: Int?

    @ObservationIgnored let keyStore: any HelioKeyStoring
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [ZeppCharacteristic: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingServices = 0
    @ObservationIgnored private var writeQueue: [ZeppWrite] = []
    @ObservationIgnored private var localStore: LocalStore?
    @ObservationIgnored private let findState = HelioFindState()
    @ObservationIgnored private var wantConnection = false
    @ObservationIgnored private var pendingAction: PendingAction?
    @ObservationIgnored private var scanTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var rssiTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    private enum PendingAction { case scan, reconnect }

    init(keyStore: any HelioKeyStoring = HelioKeyStore.shared) {
        self.keyStore = keyStore
        super.init()
        // Decision 18: backgrounding sends the find stop. Observed here rather than in a view, so it
        // holds whichever screen is showing.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session?.appDidEnterBackground()
                self?.stopRSSIUpdates()
            }
        }
    }

    // MARK: Saved strap

    nonisolated static var savedPeripheralID: String? {
        UserDefaults.standard.string(forKey: savedPeripheralKey)
    }

    /// A strap was connected before. Reads UserDefaults only: it never creates the central.
    nonisolated static var hasSavedStrap: Bool { savedPeripheralID != nil }

    func setLocalStore(_ store: LocalStore) {
        localStore = store
    }

    // MARK: User actions

    /// Connect: to the saved strap by identifier, else by a foreground search.
    func connect() {
        wantConnection = true
        if Self.hasSavedStrap, reconnectKnown() { return }
        scan()
    }

    /// A foreground search for an advertising Helio Strap (by name, §1).
    func scan() {
        wantConnection = true
        ensureCentral()
        guard central?.state == .poweredOn else {
            pendingAction = .scan
            return
        }
        pendingAction = nil
        state = .searching
        // SPEC-GAP: the strap's advertised services are unknown (§1, §10 item 1), so the scan is
        // unfiltered and matched by name. Foreground only: iOS drops unfiltered background scans.
        central?.scanForPeripherals(withServices: nil, options: nil)
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.scanTimeout))
            guard let self, !Task.isCancelled, self.state == .searching else { return }
            self.central?.stopScan()
            self.state = .notFound
        }
    }

    /// A standing connect to the saved strap (no scan). false when there is none to reconnect to.
    @discardableResult
    func reconnectKnown() -> Bool {
        guard ActiveDeviceChoiceStore.persisted() == .helioStrap,
              let id = Self.savedPeripheralID, let uuid = UUID(uuidString: id) else { return false }
        if state == .connected || state == .connecting { return true }
        wantConnection = true
        ensureCentral()
        guard central?.state == .poweredOn else {
            pendingAction = .reconnect
            return true
        }
        pendingAction = nil
        guard let known = central?.retrievePeripherals(withIdentifiers: [uuid]).first else { return false }
        adopt(known)
        state = .connecting
        central?.connect(known, options: nil)
        return true
    }

    /// Drop the link and stop reconnecting. The saved strap stays, for a later reconnect.
    func disconnect() {
        wantConnection = false
        pendingAction = nil
        scanTimeoutTask?.cancel()
        stopRSSIUpdates()
        // Never leave the strap buzzing (§15.4): the stop goes out, and gets half a second to leave
        // the radio (HelioVerify's margin), before the link is cancelled.
        let wasFinding = session?.isFinding == true
        session?.stopFind()
        session?.stopLiveHeartRate()
        session?.linkLost()
        session = nil
        state = .idle
        let central = self.central
        let peripheral = self.peripheral
        let cancel = { [weak self] in
            if central?.state == .poweredOn {
                central?.stopScan()
                if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            }
            self?.characteristics = [:]
            self?.writeQueue = []
        }
        if wasFinding {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                cancel()
            }
        } else {
            cancel()
        }
    }

    /// Forget the strap on this phone (its stored history stays).
    func forgetStrap() {
        disconnect()
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
    }

    /// Drop and re-open the link: a fresh auth with the key saved now.
    func reconnectNow() {
        let hadSaved = Self.hasSavedStrap
        disconnect()
        if hadSaved { reconnectKnown() } else { scan() }
    }

    // MARK: RSSI (Find My Strap's distance hint)

    func startRSSIUpdates() {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let peripheral = self.peripheral, peripheral.state == .connected { peripheral.readRSSI() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopRSSIUpdates() {
        rssiTask?.cancel()
        rssiTask = nil
        rssi = nil
    }

    // MARK: Plumbing

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
    }

    private func adopt(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
    }

    private func makeSession(for peripheral: CBPeripheral) {
        let store = localStore
        let session = HelioSession(
            transport: self, identityID: peripheral.identifier.uuidString, model: .helioStrap,
            key: keyStore.load(), keyStore: keyStore, sink: store.map { HelioStoreSink(store: $0) },
            findState: findState,
            onSyncFinished: { result, timeline in
                await HelioConnection.flushToHealth(result: result, timeline: timeline, store: store)
            })
        self.session = session
        session.start()
    }

    /// After every sync: the strap's timeline and nights through the ring's Health writer, carrying
    /// the strap's `HKDevice` (decisions 10–17).
    static func flushToHealth(result: HelioSyncResult, timeline: SyncDeviceID, store: LocalStore?) async {
        let observability = ObservabilityStore()
        observability.recordSyncOutcome(kind: .foreground, success: !result.interrupted && result.roundsFailed == 0,
                                        detail: "helio: \(result.roundsStored) round(s) stored, \(result.roundsFailed) failed, \(result.nights.count) night(s)")
        guard let store, HealthKitWriter.isAvailable else { return }
        let flush = await HealthKitWriter().flushToHealth(
            store: store, device: timeline, mirroredKinds: HelioHealthPolicy.healthMirroredKinds(),
            strapNights: result.nights.map(\.segments))
        if flush.wroteAnything { observability.recordHealthWrite() }
        helioLog.notice("helio: Health flush samples=\(flush.samples, privacy: .public) sleep=\(flush.sleepSegments, privacy: .public) steps=\(flush.steps, privacy: .public) rhr=\(flush.restingDays, privacy: .public)")
    }

    private func known(_ characteristic: CBCharacteristic) -> ZeppCharacteristic? {
        characteristics.first { $0.value === characteristic }?.key
    }

    // SPEC-GAP: which write types `…0016` and `…0004` accept is a §10 capture item. Write without
    // response when the characteristic offers it, else with response (HelioVerify's rule).
    private func flushWrites() {
        guard let peripheral else { return }
        while let next = writeQueue.first, let characteristic = characteristics[next.characteristic] {
            let withoutResponse = characteristic.properties.contains(.writeWithoutResponse)
            if withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            writeQueue.removeFirst()
            peripheral.writeValue(Data(next.bytes), for: characteristic,
                                  type: withoutResponse ? .withoutResponse : .withResponse)
        }
        // A write for a characteristic this strap doesn't have is dropped, never retried.
        if let next = writeQueue.first, characteristics[next.characteristic] == nil {
            writeQueue.removeFirst()
            flushWrites()
        }
    }
}

// MARK: - HelioTransport

extension HelioConnection: HelioTransport {
    func has(_ characteristic: ZeppCharacteristic) -> Bool { characteristics[characteristic] != nil }

    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool {
        guard let c = characteristics[characteristic] else { return false }
        return c.properties.contains(.notify) || c.properties.contains(.indicate)
    }

    var maxWriteLength: Int { peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20 }

    func write(_ write: ZeppWrite) {
        writeQueue.append(write)
        flushWrites()
    }

    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool) {
        guard let c = characteristics[characteristic] else { return }
        peripheral?.setNotifyValue(enabled, for: c)
    }

    func read(_ characteristic: ZeppCharacteristic) {
        guard let c = characteristics[characteristic] else { return }
        peripheral?.readValue(for: c)
    }
}

// MARK: - CBCentralManagerDelegate

extension HelioConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if state == .bluetoothOff || state == .bluetoothDenied { state = .idle }
                switch pendingAction {
                case .scan?: scan()
                case .reconnect?: reconnectKnown()
                case nil:
                    // A restored standing connect needs nothing; a restored live link is re-adopted
                    // in `willRestoreState` and discovered on connect.
                    break
                }
            case .poweredOff:
                state = .bluetoothOff
            case .unauthorized:
                state = .bluetoothDenied
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // Minimal restoration: re-adopt the saved strap's peripheral so its delegate callbacks
            // land here. If the link is already up, rediscover and start a fresh session.
            guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
                  let saved = Self.savedPeripheralID,
                  let restored = peripherals.first(where: { $0.identifier.uuidString == saved }) else { return }
            adopt(restored)
            wantConnection = true
            helioLog.notice("helio: restored the strap's peripheral (state \(restored.state.rawValue, privacy: .public))")
            if restored.state == .connected {
                state = .connected
                restored.discoverServices(nil)
            } else {
                state = .connecting
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard state == .searching else { return }
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            // §14 device gate: the Helio Strap only (the Helio Ring shares the protocol, untested).
            guard ZeppDeviceModel.match(advertisedName: name) == .helioStrap else { return }
            scanTimeoutTask?.cancel()
            central.stopScan()
            adopt(peripheral)
            state = .connecting
            helioLog.notice("helio: found the strap (RSSI \(RSSI.intValue, privacy: .public)); connecting")
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            state = .connected
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
            characteristics = [:]
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            state = .idle
            // Retry once after a pause, never in a tight loop; the retry is a standing connect that
            // iOS completes whenever the strap is in range.
            guard wantConnection else { return }
            state = .connecting
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.wantConnection, self.peripheral === peripheral,
                      self.central?.state == .poweredOn else { return }
                self.central?.connect(peripheral, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            session?.linkLost()
            session = nil
            characteristics = [:]
            writeQueue = []
            stopRSSIUpdates()
            if wantConnection, central.state == .poweredOn {
                state = .connecting
                central.connect(peripheral, options: nil)
            } else {
                state = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HelioConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            pendingServices = services.count
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                // By UUID across ALL services (§2). Never the firmware-update service.
                guard service.uuid != CBUUID(string: ZeppGATT.firmwareUpdateServiceUUID) else { continue }
                for known in ZeppCharacteristic.allCases where CBUUID(string: known.uuidString) == characteristic.uuid {
                    characteristics[known] = characteristic
                }
            }
            pendingServices -= 1
            guard pendingServices == 0, session == nil else { return }
            makeSession(for: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let which = known(characteristic) else { return }
            session?.notificationStateChanged(which, enabled: characteristic.isNotifying, failed: error != nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, let which = known(characteristic), let value = characteristic.value else { return }
            session?.received(which, [UInt8](value))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { flushWrites() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, rssiTask != nil else { return }
            rssi = RSSI.intValue
        }
    }
}
