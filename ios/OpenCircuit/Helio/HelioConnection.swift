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
// State restoration re-adopts the strap's peripheral; a session that connects then syncs on its own.
// The BGTask and Sleep Focus wakes drive it through `HelioBackgroundLink` (#215 phase 4).

@Observable
@MainActor
final class HelioConnection: NSObject {
    static let shared = HelioConnection()

    /// Constant for the life of the app: iOS hands restored state back by this identifier.
    static let restoreIdentifier = "com.standardsoftwaresolutions.opencircuit.helio"
    /// The strap's CoreBluetooth identifier (per install, never its MAC).
    nonisolated static let savedPeripheralKey = "helio.peripheralID.v1"
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
    /// The last connection ended with the strap refusing auth in a way that looks like another
    /// phone or app holds it. Nothing retries inside that connection or on a timer (no retry loop,
    /// decision 7). The next connect clears it: "Try again", or the one `reconnectKnown()` every
    /// foreground activation makes, so a busy strap costs at most one re-auth per foreground.
    private(set) var endedBusy = false

    @ObservationIgnored let keyStore: any HelioKeyStoring
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [ZeppCharacteristic: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingServices = 0
    @ObservationIgnored private var writeQueue: [ZeppWrite] = []
    @ObservationIgnored private var localStore: LocalStore?
    @ObservationIgnored private let findState = HelioFindState(defaults: .standard)
    @ObservationIgnored private var wantConnection = false
    @ObservationIgnored private var pendingAction: PendingAction?
    @ObservationIgnored private var scanTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var rssiTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    /// Background runs in progress (`HelioBackgroundLink`); a run owns the syncs of the sessions
    /// created meanwhile.
    @ObservationIgnored var activeBackgroundRuns = 0
    /// True only while a background run's watch loop runs (review-225b S-A); read by `makeSession`.
    @ObservationIgnored var backgroundRunAdoptsNewSessions = false

    private enum PendingAction { case scan, reconnect, resumeRestored }

    init(keyStore: (any HelioKeyStoring)? = nil) {
        self.keyStore = keyStore ?? HelioKeyStore.shared
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

    /// This connection has created its central (decision 1's tests: the strap's central exists only
    /// while the strap is the chosen device).
    var hasCentral: Bool { central != nil }

    // MARK: User actions

    /// Connect: to the saved strap by identifier, else by a foreground search.
    func connect() {
        endedBusy = false
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
        endedBusy = false
        guard ActiveDeviceChoiceStore.persisted() == .helioStrap,
              let id = Self.savedPeripheralID, let uuid = UUID(uuidString: id) else { return false }
        if state == .connecting || (state == .connected && session != nil) { return true }
        if state == .connected, let peripheral, peripheral.state == .connected, central?.state == .poweredOn {
            // Linked but no session (a discovery that never finished): discover again.
            characteristics = [:]
            peripheral.discoverServices(nil)
            return true
        }
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
        // A sync in progress gets its `03 09` before the link goes (the strap keeps the data either way).
        let wasBusy = session?.isFinding == true || session?.syncing == true
        session?.stopFind()
        session?.stopLiveHeartRate()
        session?.abortSync()
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
        if wasBusy {
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
        let wasFinding = session?.isFinding == true || session?.syncing == true
        disconnect()
        let reopen = { [weak self] in
            guard let self else { return }
            // A saved strap the system no longer knows falls back to a search.
            if !(Self.hasSavedStrap && self.reconnectKnown()) { self.scan() }
        }
        if wasFinding {
            // `disconnect()` gives a running find's stop half a second before cancelling the link;
            // reopen after that, so the cancel can't land on the new connect.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                reopen()
            }
        } else {
            reopen()
        }
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
        // The process-wide container when no view handed a store over yet (a switch made from a
        // screen, or a restoration launch), opened now if launch couldn't (before the first unlock);
        // never `makeContainer()`, whose recovery path can wipe.
        let store = localStore ?? (try? OpenCircuitApp.backgroundStore())
        let session = HelioSession(
            transport: self, identityID: peripheral.identifier.uuidString, model: .helioStrap,
            key: keyStore.load(), keyStore: keyStore, sink: store.map { HelioStoreSink(store: $0) },
            findState: findState,
            onSyncFinished: { result, timeline in
                // A background run flushes and logs the syncs it owns itself (#215 phase 4).
                guard !result.endedInBackgroundRun else { return }
                await HelioConnection.flushToHealth(result: result, timeline: timeline, store: store)
            })
        session.backgroundRunOwnsSyncs = backgroundRunAdoptsNewSessions
        self.session = session
        session.start()
    }

    /// After every sync no background run owns: the strap's timeline and nights through the ring's
    /// Health writer, carrying the strap's `HKDevice` (decisions 10–17). Logged as a foreground sync
    /// only while the app is active; one that ends in the background (a restoration relaunch, a link
    /// that came back while suspended) is logged as a background sync.
    static func flushToHealth(result: HelioSyncResult, timeline: SyncDeviceID, store: LocalStore?) async {
        let observability = ObservabilityStore()
        let kind: TaskRecord.Kind = UIApplication.shared.applicationState == .active ? .foreground : .backgroundSync
        observability.recordSyncOutcome(kind: kind, success: !result.interrupted && result.roundsFailed == 0,
                                        detail: "helio: \(result.roundsStored) round(s) stored, \(result.roundsFailed) failed, \(result.nights.count) night(s)")
        guard let store else { return }
        guard let flush = await healthFlush(timeline: timeline, store: store, nights: result.nights,
                                            identity: result.identity) else { return }
        if flush.wroteAnything { observability.recordHealthWrite() }
    }

    /// The strap's Apple Health pass, shared by the post-sync hook and the background run (#215
    /// phase 4): its timeline's pending samples (HRV withheld, decision 14) and `nights`. nil when
    /// Health isn't available on this device, or when `mayFlush` says no. `nightsFinalized` skips
    /// the nights' 20-minute quiet margin (the Sleep Focus wake, as for the ring).
    static func healthFlush(timeline: SyncDeviceID, store: LocalStore, nights: [HelioSleepSelection.Night],
                            identity: WearableIdentity?, nightsFinalized: Bool = false) async -> HealthKitWriter.FlushResult? {
        guard HealthKitWriter.isAvailable else { return nil }
        // Decision 28 (review-224 S3): record the identity the sync ended with, so this flush — and
        // any later one for these rows — names THIS strap even if the wearer has switched back to
        // the ring meanwhile. A strap that never passed the first-write guard writes nothing once
        // it's no longer chosen; its rows stay pending for its next sync.
        if let identity { ActiveWearable.shared.recordIdentity(identity) }
        guard mayFlush(timeline: timeline, strapChosen: ActiveDeviceChoiceStore.shared.isHelio,
                       wearable: ActiveWearable.shared) else {
            helioLog.notice("helio: Health flush skipped: switched away before the strap had an identity")
            return nil
        }
        let flush = await HealthKitWriter().flushToHealth(
            store: store, device: timeline, mirroredKinds: HelioHealthPolicy.healthMirroredKinds(),
            strapNights: nights.map(\.segments), strapNightsFinalized: nightsFinalized)
        helioLog.notice("helio: Health flush samples=\(flush.samples, privacy: .public) sleep=\(flush.sleepSegments, privacy: .public) steps=\(flush.steps, privacy: .public) rhr=\(flush.restingDays, privacy: .public)")
        return flush
    }

    /// Whether a strap sync's flush may write (decision 28, review-224 S3). Attribution follows the
    /// row: the strap's rows name the strap. While the strap is chosen that follows the first-write
    /// guard (#222: no identity yet → no device attached); once it isn't, a write with no identity
    /// would be anonymous rows from a device the wearer has left, so nothing is written.
    static func mayFlush(timeline: SyncDeviceID, strapChosen: Bool, wearable: ActiveWearable) -> Bool {
        strapChosen || wearable.identityForHealthWrite(timeline: timeline) != nil
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

// MARK: - HelioBackgroundLink

extension HelioConnection: HelioBackgroundLink {
    var strapTimeline: SyncDeviceID? {
        if let session { return session.timeline }
        return Self.savedPeripheralID.map {
            SyncDeviceID.timeline(for: .zeppOS(model: HelioSession.displayName), identityID: $0)
        }
    }

    func connectForBackground() -> Bool {
        reconnectKnown()
    }

    func disconnectForBackground() {
        // `disconnect()` drops the session before the link goes, so `didDisconnectPeripheral` can't see
        // a busy strap any more: note it here, so nothing reconnects by itself (decision 7).
        if session?.phase == .strapBusy { endedBusy = true }
        disconnect()
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
                case .resumeRestored?: resumeRestored()
                case nil: break
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
            // Minimal restoration: re-adopt the saved strap's peripheral so its callbacks land here.
            // Nothing is sent to the radio yet (CoreBluetooth ignores calls before power-on); the
            // `.poweredOn` update resumes it (`resumeRestored`).
            guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
                  let saved = Self.savedPeripheralID,
                  let restored = peripherals.first(where: { $0.identifier.uuidString == saved }) else { return }
            adopt(restored)
            wantConnection = true
            pendingAction = .resumeRestored
            state = restored.state == .connected ? .connected : .connecting
            helioLog.notice("helio: restored the strap's peripheral (state \(restored.state.rawValue, privacy: .public))")
        }
    }

    /// After restoration and power-on: discover a live link, or re-issue the standing connect.
    private func resumeRestored() {
        pendingAction = nil
        guard let peripheral, wantConnection, central?.state == .poweredOn else { return }
        if peripheral.state == .connected {
            state = .connected
            if session == nil { characteristics = [:]; peripheral.discoverServices(nil) }
        } else {
            state = .connecting
            central?.connect(peripheral, options: nil)
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
            // Auth refused as "busy" on this connection: don't reconnect by itself, or a strap held
            // by another app would be re-authenticated in a loop.
            if session?.phase == .strapBusy {
                endedBusy = true
                wantConnection = false
            }
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
            guard error == nil, !services.isEmpty else {
                // A discovery that failed would leave "connected" with no session: drop the link
                // instead, so the standing reconnect starts over.
                helioLog.error("helio: service discovery failed; reconnecting")
                central?.cancelPeripheralConnection(peripheral)
                return
            }
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
