import Foundation
import Observation
import OpenCircuitKit
import os
import ZeppKit

// The Amazfit Helio Strap as a `WearableSession` (#215 phase 3). One session per connection, like
// `RingSession`. It holds no CoreBluetooth: `HelioConnection` moves bytes between the radio and this
// class through `HelioTransport`, so the whole flow runs in tests against `FakeZeppDevice`.
//
// Connection sequence, mirroring HelioVerify (proven on a real strap, ZEPP_PROTOCOL.md §10.1):
//   read DIS hardware revision + battery level → enable notify on …0017 (+ …0016) → auth (§4) →
//   services list (§5.2) → device info (§5.3) → battery (§5.3) → set the clock (§5.1, decision 9) →
//   HEALTH recording switches (§5.5) → find-device capabilities (§11.2) → alarm list (§12) →
//   haptic alert settings (§13.4, read-only) → history fetch over Path A (§6), then Apple Health.
// Without a usable key the session stays keyless: standard 0x2A37 heart rate only, if the strap
// sends it unauthenticated (§7.1 Tier 0, decision 7). Nothing is ever written at setup except the
// clock (§15.1); alarm writes happen only on an explicit user edit, one slot at a time.

let helioLog = Logger(subsystem: "com.standardsoftwaresolutions.opencircuit", category: "helio")

/// The link-level half of a strap connection. `HelioConnection` implements it over CoreBluetooth;
/// the tests implement it over `FakeZeppDevice`.
@MainActor
protocol HelioTransport: AnyObject {
    /// The characteristic was discovered on this connection.
    func has(_ characteristic: ZeppCharacteristic) -> Bool
    /// The characteristic supports notifications.
    func canNotify(_ characteristic: ZeppCharacteristic) -> Bool
    /// The "(MTU − 3)" term for chunking (§3.2): the OS-negotiated value, never a hard-coded one.
    var maxWriteLength: Int { get }
    func write(_ write: ZeppWrite)
    func setNotify(_ characteristic: ZeppCharacteristic, enabled: Bool)
    func read(_ characteristic: ZeppCharacteristic)
}

/// One reading shown in the app only (stress, PAI: decision 15).
struct HelioReading: Equatable {
    let value: Double
    let at: Date
}

/// What one history sync delivered.
struct HelioSyncResult: Equatable {
    /// The strap's staged nights stored this sync (manually edited nights excluded), for Apple Health.
    var nights: [HelioSleepSelection.Night] = []
    var roundsStored = 0
    var roundsFailed = 0
    /// Types the strap had nothing new for.
    var typesEmpty = 0
    var todaySteps: Int?
    var latestStress: HelioReading?
    var latestPAI: HelioReading?
    /// The sync ended early (link lost, or no progress for too long).
    var interrupted = false
    /// The strap's identity when the sync ended, so its Health flush names the strap even if the
    /// person switched devices meanwhile (review-224 S3: attribution follows the row).
    var identity: WearableIdentity?
}

/// Where fetched rounds go. `HelioStoreSink` is the `LocalStore` implementation.
@MainActor
protocol HelioHistorySink: AnyObject {
    /// Each type's persisted watermark on `timeline`.
    func fetchCursors(timeline: SyncDeviceID) -> [ZeppFetchType: Date]
    /// No fetch starts before this (decision 28: the strap's current ownership start).
    func notBefore(timeline: SyncDeviceID, now: Date) -> Date?
    func beginSync(timeline: SyncDeviceID, now: Date)
    /// Store one round and advance its type's watermark. true only when both are durably saved.
    func persist(_ round: ZeppFetchRound, timeline: SyncDeviceID, now: Date) -> Bool
    /// Every round of this sync is in: finish the per-night work and report.
    func finishSync(timeline: SyncDeviceID, now: Date) -> HelioSyncResult
}

/// The find-device machine outlives a connection: it carries a stop owed since the link dropped
/// mid-find to the next connection (§11.4, §15.4). `HelioConnection` owns one and lends it to each
/// session.
@MainActor
final class HelioFindState {
    var machine: ZeppFindDevice

    /// Decision 18: the app stops a find after 60 s. Decision 19: a buzz is 2 s.
    static let configuration = ZeppFindDevice.Configuration(maxDuration: 60, buzzLength: 2)

    init(configuration: ZeppFindDevice.Configuration? = nil) {
        machine = ZeppFindDevice(configuration: configuration ?? Self.configuration)
    }
}

@Observable
@MainActor
final class HelioSession: WearableSession {

    enum Phase: Equatable {
        /// Characteristics discovered; the basics are being read.
        case starting
        /// No key saved: standard heart rate only, if the strap sends it (decision 7).
        case keyless
        case authenticating
        /// The strap answered `10 05 25`: the key is wrong or was invalidated. Never retried.
        case keyRejected
        /// Auth failed another way, or the strap didn't answer: another phone or app probably holds
        /// it (§9 "Competing central"). Not retried on this connection.
        case strapBusy
        /// The strap lacks the characteristics this app needs.
        case unsupported
        case settingUp
        case ready
        case syncing
    }

    /// Decision 8: v1 always acks keep-on-strap (`03 09`). There is no delete path in the app.
    static let ackPolicy: ZeppAckPolicy = .keepOnDevice
    /// How long auth may take before the strap is reported busy.
    static let authTimeout: TimeInterval = 10
    /// How long a setup step waits for its reply (the same 5 s HelioVerify and ZeppKit use).
    static let stepTimeout: TimeInterval = 5
    /// A sync with no fetch traffic for this long is aborted (with `03 09`).
    static let syncStallTimeout: TimeInterval = 90
    /// Decision 11's name for the strap in Apple Health and on screen.
    static let displayName = "Helio Strap"

    // MARK: Identity

    /// The strap's CoreBluetooth peripheral UUID: per install, never its MAC.
    let identityID: String
    let model: ZeppDeviceModel
    /// Where everything this strap measures is stored: `zeppos:<identityID>` (decision 10).
    let timeline: SyncDeviceID
    private(set) var hardwareVersion: String?
    private(set) var firmwareVersion: String?

    // MARK: Observable state

    private(set) var phase: Phase = .starting
    private(set) var isLinkConnected = true
    private(set) var lastFrameAt: Date?
    private(set) var batteryPercent: Int?
    private(set) var charging = false
    private(set) var liveHR: Int?
    private(set) var liveHRAt: Date?
    /// The authenticated heart-rate stream (§7.1) is running.
    private(set) var liveHeartRateRunning = false
    /// Who started the running stream: the Measure control (90 s), or a workout (until it ends, #227).
    private(set) var liveHeartRateOwner: LiveHeartRateOwner?
    /// Standard heart-rate notifications arrived without auth (Tier 0) on this connection.
    private(set) var tierZeroHeartRateSeen = false
    private(set) var steps: Int?
    private(set) var syncStatus: String?
    private(set) var lastSyncAt: Date?
    private(set) var lastSyncResult: HelioSyncResult?
    private(set) var services: ZeppServicesList?
    private(set) var controlCapabilities: ZeppControlCapabilities = .disconnected
    /// HEALTH switches that are off, so the matching history comes back empty (§5.5).
    private(set) var recordingWarnings: [String] = []
    /// The strap confirmed the clock set on this connection (`06 01`, decision 9).
    private(set) var clockSet = false
    private(set) var alarmEditor: ZeppAlarmEditor?
    /// The last alarm outcome, in plain language, for the alarm screen.
    private(set) var alarmNotice: String?
    private(set) var configCapabilities: ZeppConfigCapabilities?
    private(set) var hapticAlerts: ZeppHapticAlertSettings?
    /// Mirrors of the shared find machine, so the find screen re-renders.
    private(set) var findPhase: ZeppFindDevice.State = .idle
    private(set) var findVersion: UInt8?
    /// Every acknowledgement byte sent for a fetch round on this connection, in order (always `09`).
    private(set) var fetchAcksSent: [UInt8] = []

    // MARK: Collaborators

    @ObservationIgnored private weak var transport: (any HelioTransport)?
    @ObservationIgnored private let key: ZeppAuthKey?
    @ObservationIgnored private let keyStore: (any HelioKeyStoring)?
    @ObservationIgnored private let sink: (any HelioHistorySink)?
    @ObservationIgnored private let findState: HelioFindState
    @ObservationIgnored private let onSyncFinished: @MainActor (HelioSyncResult, SyncDeviceID) async -> Void
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let random: ZeppRandom
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private let autoSyncOnConnect: Bool
    /// True while the app records a workout on this strap (#227): history syncs wait until it ends.
    @ObservationIgnored private let workoutHoldsLink: @MainActor () -> Bool
    /// Every valid heart-rate reading, as it arrives (the workout recorder, #227).
    @ObservationIgnored var heartRateObserver: (@MainActor (Int, Date) -> Void)?

    // MARK: Protocol state

    @ObservationIgnored private var link: ZeppLink?
    @ObservationIgnored private var fetch: ZeppHistoryFetch?
    @ObservationIgnored private var pendingNotify = Set<ZeppCharacteristic>()
    @ObservationIgnored private var notifyPurpose: NotifyPurpose?
    @ObservationIgnored private var authDeadline: Date?
    @ObservationIgnored private var setupQueue: [SetupStep] = []
    @ObservationIgnored private var currentStep: SetupStep?
    @ObservationIgnored private var stepDeadline: Date?
    @ObservationIgnored private var lastFetchProgressAt: Date?
    @ObservationIgnored private var syncCounts = (stored: 0, failed: 0, empty: 0)
    @ObservationIgnored private var liveHRKeepAliveAt: Date?
    @ObservationIgnored private var liveHREndsAt: Date?
    /// When the workout stream was last (re)started, for its restart watchdog.
    @ObservationIgnored private var liveHRStartedAt: Date?
    @ObservationIgnored private var disHardwareRevision: String?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private enum NotifyPurpose { case auth, fetch }

    enum LiveHeartRateOwner: Equatable { case measure, workout }

    /// A workout started the heart-rate stream and no reading has arrived for this long: send the
    /// start again (#227).
    // SPEC-GAP: §7.1 says only that `04 02` every second keeps the stream running. Whether the strap
    // ever stops on its own (a maximum duration, or after the keep-alive paused while the app was
    // suspended), and whether `04 02` alone restarts it, is not specified. A stalled stream is
    // restarted with `04 01`, at most once per this interval.
    static let workoutStreamRestartAfter: TimeInterval = 10

    private enum SetupStep: Equatable {
        case servicesList, deviceInfo, battery, setTime, healthConfig
        case findCapabilities, alarms, alertCapabilities, alertSettings
    }

    init(transport: any HelioTransport, identityID: String, model: ZeppDeviceModel = .helioStrap,
         key: ZeppAuthKey?, keyStore: (any HelioKeyStoring)?, sink: (any HelioHistorySink)?,
         findState: HelioFindState,
         onSyncFinished: @escaping @MainActor (HelioSyncResult, SyncDeviceID) async -> Void = { _, _ in },
         clock: @escaping () -> Date = Date.init, random: ZeppRandom = .system,
         autoTick: Bool = true, autoSyncOnConnect: Bool = true,
         workoutHoldsLink: @escaping @MainActor () -> Bool = { false }) {
        self.transport = transport
        self.identityID = identityID
        self.model = model
        self.key = key
        self.keyStore = keyStore
        self.sink = sink
        self.findState = findState
        self.onSyncFinished = onSyncFinished
        self.clock = clock
        self.random = random
        self.autoTick = autoTick
        self.autoSyncOnConnect = autoSyncOnConnect
        self.workoutHoldsLink = workoutHoldsLink
        timeline = SyncDeviceID.timeline(for: .zeppOS(model: Self.displayName), identityID: identityID)
        findPhase = findState.machine.state
    }

    // MARK: WearableSession

    var deviceKind: WearableDeviceKind { .zeppOS(model: Self.displayName) }

    /// Decision 11: name "Helio Strap", manufacturer "Amazfit" (`WearableDeviceKind.brand`), model
    /// from the advertised product, hardware and firmware from the strap's own reads when present.
    var identity: WearableIdentity {
        WearableIdentity(id: identityID, kind: deviceKind, name: Self.displayName,
                         hardwareVersion: hardwareVersion, firmwareVersion: firmwareVersion)
    }

    /// The seam's flags, intersected with what THIS connection proved (`ZeppControlCapabilities`,
    /// decision 22): unknown is unsupported.
    var capabilities: WearableCapabilities {
        var caps: WearableCapabilities = []
        if isAuthenticated { caps.formUnion([.historySync, .skinTemperature]) }
        if batteryPercent != nil { caps.insert(.battery) }
        if canStreamHeartRate || tierZeroHeartRateSeen { caps.insert(.liveHeartRate) }
        if controlCapabilities.isSupported(.findDevice) { caps.insert(.findMyDevice) }
        if controlCapabilities.isSupported(.buzz) { caps.insert(.vibration) }
        if controlCapabilities.isSupported(.alarms), alarmEditor?.malformedList == nil { caps.insert(.alarm) }
        return caps
    }

    var ready: Bool { isLinkConnected && (phase == .ready || phase == .syncing) }
    var syncing: Bool { phase == .syncing }
    var isAuthenticated: Bool { link?.isAuthenticated == true }
    /// A find or buzz is running (from the observable mirror, so views re-render).
    var isFinding: Bool {
        if case .buzzing = findPhase { return true }
        return false
    }

    /// Authenticated heart-rate streaming is possible on this connection (§7.1).
    var canStreamHeartRate: Bool {
        isAuthenticated && services?.contains(ZeppEndpoint.heartRate) == true
            && transport?.has(.heartRateMeasurement) == true
    }

    func syncHistory(manual: Bool) {
        // A workout holds the link (#227), like the ring's (T6): the sync runs when it ends.
        // SPEC-GAP: whether a history fetch (…0004/…0005) and the heart-rate stream (`0x001D`) can
        // run together on one connection is not specified, so they never do.
        guard !workoutHoldsLink() else {
            if manual { syncStatus = "Syncs after the workout ends" }
            helioLog.notice("helio: sync deferred, a workout holds the link")
            return
        }
        guard phase == .ready, isAuthenticated else {
            if manual { syncStatus = phase == .syncing ? "Already syncing" : "Not ready to sync" }
            return
        }
        guard let transport, transport.has(.activityControl), transport.has(.activityData), sink != nil else {
            syncStatus = "This strap doesn't offer history over Bluetooth"
            return
        }
        phase = .syncing
        syncStatus = "Syncing…"
        lastFetchProgressAt = clock()
        notifyPurpose = .fetch
        pendingNotify = [.activityControl, .activityData]
        transport.setNotify(.activityControl, enabled: true)
        transport.setNotify(.activityData, enabled: true)
        helioLog.notice("helio: sync started (\(manual ? "manual" : "on connect", privacy: .public))")
    }

    // MARK: Connection lifecycle (called by HelioConnection)

    /// The characteristics are known: read the basics, then authenticate or stay keyless.
    func start() {
        guard let transport else { return }
        for characteristic in [ZeppCharacteristic.hardwareRevision, .batteryLevel] where transport.has(characteristic) {
            transport.read(characteristic)
        }
        if autoTick { startTicking() }
        guard let key, keyStore?.isRejected != true else {
            phase = keyStore?.isRejected == true ? .keyRejected : .keyless
            helioLog.notice("helio: \(self.phase == .keyRejected ? "key rejected earlier" : "no key", privacy: .public); standard heart rate only")
            startTierZero()
            return
        }
        guard transport.has(.chunkedRead), transport.has(.chunkedWrite) else {
            phase = .unsupported
            helioLog.error("helio: chunked characteristics …0016/…0017 not found")
            return
        }
        link = ZeppLink(authKey: key, random: random, maxWriteLength: transport.maxWriteLength)
        phase = .authenticating
        notifyPurpose = .auth
        pendingNotify = [.chunkedRead]
        if transport.canNotify(.chunkedWrite) { pendingNotify.insert(.chunkedWrite) }
        authDeadline = clock().addingTimeInterval(Self.authTimeout)
        for characteristic in pendingNotify { transport.setNotify(characteristic, enabled: true) }
    }

    /// CoreBluetooth reported a notification state change.
    func notificationStateChanged(_ characteristic: ZeppCharacteristic, enabled: Bool, failed: Bool) {
        // Only an ENABLE (or a failure) settles a pending entry: a late "off" from the previous
        // sync's teardown must not start the next fetch before notify is back on.
        guard pendingNotify.contains(characteristic), enabled || failed else { return }
        if failed {
            pendingNotify.removeAll()
            switch notifyPurpose {
            case .auth?: failAuthentication(busy: true, reason: "notify on \(characteristic.rawValue) failed")
            case .fetch?: finishFetch(interrupted: true)
            case nil: break
            }
            notifyPurpose = nil
            return
        }
        pendingNotify.remove(characteristic)
        guard pendingNotify.isEmpty else { return }
        let purpose = notifyPurpose
        notifyPurpose = nil
        switch purpose {
        case .auth?: startAuthentication()
        case .fetch?: startFetch()
        case nil: break
        }
    }

    /// A read response or a notification.
    func received(_ characteristic: ZeppCharacteristic, _ bytes: [UInt8]) {
        let now = clock()
        lastFrameAt = now
        switch characteristic {
        case .hardwareRevision:
            let text = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            disHardwareRevision = text.isEmpty ? nil : text
            if hardwareVersion == nil { hardwareVersion = disHardwareRevision }
        case .firmwareRevision:
            // Not exposed by the Helio (§1); kept for another Zepp OS model.
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if firmwareVersion == nil, !text.isEmpty { firmwareVersion = text }
        case .batteryLevel:
            if let level = ZeppBatteryLevelCharacteristic.parse(bytes), !isAuthenticated { batteryPercent = level }
        case .heartRateMeasurement:
            guard let measurement = ZeppHeartRateMeasurement.parse(bytes),
                  LiveHR.validBPM.contains(measurement.beatsPerMinute) else { return }
            liveHR = measurement.beatsPerMinute
            liveHRAt = now
            if !isAuthenticated { tierZeroHeartRateSeen = true }
            heartRateObserver?(measurement.beatsPerMinute, now)
        case .chunkedRead, .chunkedWrite:
            guard var link else { return }
            let out = link.receive(bytes)
            self.link = link
            handle(out)
        case .activityControl:
            guard var fetch else { return }
            lastFetchProgressAt = now
            let actions = fetch.receiveControl(bytes)
            self.fetch = fetch
            perform(actions)
        case .activityData:
            guard var fetch else { return }
            lastFetchProgressAt = now
            let actions = fetch.receiveData(bytes)
            self.fetch = fetch
            perform(actions)
        case .currentTime:
            break
        }
    }

    /// The link dropped. A running find owes its stop to the next connection; a fetch round in
    /// progress can't be acked (the strap keeps unacked data, §6.3); what was stored stays stored.
    func linkLost() {
        isLinkConnected = false
        findState.machine.connectionLost()
        findPhase = findState.machine.state
        if fetch != nil || phase == .syncing { finishFetch(interrupted: true) }
        liveHeartRateRunning = false
        liveHeartRateOwner = nil
        liveHRKeepAliveAt = nil
        liveHREndsAt = nil
        liveHRStartedAt = nil
        authDeadline = nil
        stepDeadline = nil
        tickTask?.cancel()
        tickTask = nil
        helioLog.notice("helio: link lost")
    }

    /// A user disconnect mid-sync: ack the open round `03 09` while the link is still up (the strap
    /// keeps the data either way), then let `linkLost` finish the sync as interrupted.
    func abortSync() {
        guard var fetch else { return }
        let actions = fetch.abort()
        self.fetch = fetch
        perform(actions)
    }

    /// Decision 18: backgrounding stops a find; a Measure stream stops too. A workout's stream keeps
    /// running (#227): the workout's location session keeps the app alive, as the ring's does.
    func appDidEnterBackground() {
        stopFind()
        if liveHeartRateOwner != .workout { stopLiveHeartRate() }
    }

    // MARK: Time

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick(now: self.clock())
            }
        }
    }

    /// Timeouts, the find machine's stops, the alarm editor's reply timeouts, the live-HR
    /// keep-alive and the sync watchdog. Production calls it every 250 ms; tests call it directly.
    func tick(now: Date) {
        if let authDeadline, now >= authDeadline, phase == .authenticating {
            failAuthentication(busy: true, reason: "no auth reply in \(Int(Self.authTimeout)) s")
        }
        if findState.machine.nextDeadline.map({ now >= $0 }) == true {
            performFind(findState.machine.tick(now: now))
        }
        if var editor = alarmEditor, editor.nextDeadline.map({ now >= $0 }) == true {
            let out = editor.tick(now: now)
            alarmEditor = editor
            performAlarm(out)
        }
        if let stepDeadline, now >= stepDeadline {
            helioLog.notice("helio: setup step \(String(describing: self.currentStep), privacy: .public) timed out")
            nextSetupStep()
        }
        if liveHeartRateRunning {
            if let end = liveHREndsAt, now >= end {
                stopLiveHeartRate()
            } else if liveHeartRateOwner == .workout, let started = liveHRStartedAt,
                      now.timeIntervalSince(max(liveHRAt ?? started, started)) >= Self.workoutStreamRestartAfter {
                helioLog.notice("helio: workout heart rate stalled; sending start again")
                send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
                liveHRStartedAt = now
                liveHRKeepAliveAt = now.addingTimeInterval(1)
            } else if let next = liveHRKeepAliveAt, now >= next {
                send(ZeppEndpoint.heartRate, ZeppHeartRateControl.keepRunning)
                liveHRKeepAliveAt = now.addingTimeInterval(1)
            }
        }
        if phase == .syncing, let last = lastFetchProgressAt, now.timeIntervalSince(last) > Self.syncStallTimeout {
            helioLog.error("helio: sync stalled; aborting with 03 09")
            if var fetch {
                let actions = fetch.abort()
                self.fetch = fetch
                perform(actions)
            }
            finishFetch(interrupted: true)
        }
    }

    // MARK: Auth (§4)

    private func startAuthentication() {
        guard var link else { return }
        helioLog.notice("helio: authenticating")
        let out = link.startAuthentication()
        self.link = link
        handle(out)
    }

    private func failAuthentication(busy: Bool, reason: String) {
        authDeadline = nil
        link = nil
        phase = busy ? .strapBusy : .keyRejected
        helioLog.error("helio: auth failed (\(reason, privacy: .public))")
        startTierZero()
    }

    private func handle(_ out: ZeppLink.Output) {
        for write in out.writes { transport?.write(write) }
        for event in out.events {
            switch event {
            case .authenticated:
                authDeadline = nil
                helioLog.notice("helio: authenticated")
                beginSetup()
            case .authenticationFailed(.wrongAuthKey):
                // Decision 7: "key rejected", never a retry loop. The mark stays until the key changes.
                keyStore?.markRejected()
                failAuthentication(busy: false, reason: "10 05 25, wrong key")
            case .authenticationFailed(let failure):
                failAuthentication(busy: true, reason: "\(failure)")
            case .message(let message):
                handleMessage(message)
            case .undecryptable(let endpoint):
                helioLog.error("helio: could not decrypt a message on 0x\(String(format: "%04x", endpoint), privacy: .public)")
            case .droppedChunk, .deviceChunkAck:
                break
            }
        }
    }

    private func send(_ endpoint: UInt16, _ payload: [UInt8]) {
        guard var link else { return }
        do {
            let writes = try link.send(endpoint: endpoint, payload: payload)
            self.link = link
            for write in writes { transport?.write(write) }
        } catch {
            helioLog.error("helio: cannot send to 0x\(String(format: "%04x", endpoint), privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ messages: [ZeppControlMessage]) {
        for message in messages { send(message.endpoint, message.payload) }
    }

    // MARK: Setup (§5, §11–§14)

    private func beginSetup() {
        phase = .settingUp
        setupQueue = [.servicesList, .deviceInfo, .battery, .setTime, .healthConfig,
                      .findCapabilities, .alarms, .alertCapabilities, .alertSettings]
        nextSetupStep()
    }

    private func nextSetupStep() {
        currentStep = nil
        stepDeadline = nil
        while !setupQueue.isEmpty {
            let step = setupQueue.removeFirst()
            // Marked current BEFORE the request goes out, so a reply that arrives within the same
            // call still finds its step.
            currentStep = step
            stepDeadline = clock().addingTimeInterval(Self.stepTimeout)
            if run(step) { return }
            currentStep = nil
            stepDeadline = nil
        }
        setupFinished()
    }

    /// Sends the step's request. true when a reply is awaited.
    private func run(_ step: SetupStep) -> Bool {
        let listed = { (endpoint: UInt16) in self.services?.contains(endpoint) == true }
        switch step {
        case .servicesList:
            send(ZeppEndpoint.servicesList, ZeppServicesList.request)
            return true
        case .deviceInfo:
            guard listed(ZeppEndpoint.deviceInfo) else { return false }
            send(ZeppEndpoint.deviceInfo, ZeppDeviceInfo.request)
            return true
        case .battery:
            guard listed(ZeppEndpoint.battery) else { return false }
            send(ZeppEndpoint.battery, ZeppBatteryStatus.request)
            return true
        case .setTime:
            // Decision 9: the phone's current local time on every connection, after auth. No DST
            // transition command (`07`) in v1.
            let now = clock()
            if listed(ZeppEndpoint.time) {
                send(ZeppEndpoint.time, ZeppTimeCommand.setTime(now, timeZone: .current))
                return true
            }
            if transport?.has(.currentTime) == true {
                // SPEC-GAP: the 0x2A2B fallback has no reply, so it never enables alarm edits (§14).
                transport?.write(ZeppWrite(.currentTime, ZeppTimeCommand.currentTimeBytes(now, timeZone: .current)))
                helioLog.notice("helio: clock set via 0x2A2B (no reply)")
            }
            return false
        case .healthConfig:
            guard listed(ZeppEndpoint.config) else { return false }
            // The hardware-validated read (#223): byte-identical to what HelioVerify sent on a real
            // strap (§10.1 item 8), `03 00 08 07 01 04 05 11 12 13 31`. It includes `0x04`, which is
            // read but never shown as a warning (`recordingWarnings`).
            let request = ZeppConfig.readRequest(group: ZeppConfig.healthGroup, arguments: ZeppConfig.healthReadArguments)
            let spaced = request.map { String(format: "%02x", $0) }.joined(separator: " ")
            helioLog.notice("helio: HEALTH read \(spaced, privacy: .public)")   // control bytes only
            send(ZeppEndpoint.config, request)
            return true
        case .findCapabilities:
            // Sends a stop owed since a link loss first (decision 18), then the read-only `01`.
            let out = findState.machine.connected(controlCapabilities)
            performFind(out)
            return controlCapabilities.isSupported(.findDevice)
        case .alarms:
            guard var editor = alarmEditor, controlCapabilities.isSupported(.alarms) else { return false }
            do {
                let out = try editor.read(now: clock())
                alarmEditor = editor
                performAlarm(out)
                return true
            } catch {
                return false
            }
        case .alertCapabilities:
            guard controlCapabilities.isSupported(.hapticAlerts) else { return false }
            send(ZeppEndpoint.config, ZeppConfigCapabilities.request)
            return true
        case .alertSettings:
            guard configCapabilities?.groups.contains(ZeppConfig.healthGroup) == true else { return false }
            send(ZeppEndpoint.config, ZeppHapticAlertSettings.readRequest)
            return true
        }
    }

    private func advance(from step: SetupStep) {
        guard currentStep == step else { return }
        nextSetupStep()
    }

    private func setupFinished() {
        phase = .ready
        helioLog.notice("helio: ready (clock \(self.clockSet ? "set" : "NOT set", privacy: .public), controls: find \(self.controlCapabilities.isSupported(.findDevice), privacy: .public), alarms \(self.controlCapabilities.isSupported(.alarms), privacy: .public))")
        if autoSyncOnConnect { syncHistory(manual: false) }
    }

    private func handleMessage(_ message: ZeppMessage) {
        let payload = message.payload
        switch message.endpoint {
        case ZeppEndpoint.servicesList:
            guard currentStep == .servicesList else { return }
            if let list = ZeppServicesList.parse(payload) {
                services = list
                link?.apply(servicesList: list)
                controlCapabilities = ZeppControlCapabilities(model: model, isAuthenticated: isAuthenticated, services: list)
                alarmEditor = ZeppAlarmEditor(capabilities: controlCapabilities)
                helioLog.notice("helio: services list, \(list.entries.count) endpoints")
            } else {
                helioLog.error("helio: malformed services list; controls stay off")
            }
            advance(from: .servicesList)
        case ZeppEndpoint.deviceInfo:
            if let info = ZeppDeviceInfo.parse(payload), !info.isAmbiguous {
                // A mis-located field could shift the serial number into a version (the SPEC-GAP in
                // ZeppDeviceInfo.parse). When DIS gave a hardware revision and this one differs, keep
                // neither version (HelioVerify's rule).
                if let dis = disHardwareRevision, let hardware = info.hardwareVersion, dis != hardware {
                    helioLog.notice("helio: device info disagrees with DIS; versions withheld")
                } else {
                    if let hardware = info.hardwareVersion { hardwareVersion = hardware }
                    if let firmware = info.firmwareVersion { firmwareVersion = firmware }
                }
            }
            advance(from: .deviceInfo)
        case ZeppEndpoint.battery:
            if let battery = ZeppBatteryStatus.parse(payload) {
                batteryPercent = battery.level
                charging = battery.isCharging ?? false
            }
            advance(from: .battery)
        case ZeppEndpoint.time:
            guard currentStep == .setTime else { return }
            clockSet = ZeppTimeCommand.isSuccessReply(payload)
            if var editor = alarmEditor {
                editor.noteTimeSetReply(payload)
                alarmEditor = editor
            }
            helioLog.notice("helio: clock \(self.clockSet ? "set" : "set: unexpected reply", privacy: .public)")
            advance(from: .setTime)
        case ZeppEndpoint.config:
            handleConfig(payload)
        case ZeppEndpoint.findDevice:
            performFind(findState.machine.receive(payload, now: clock()))
        case ZeppEndpoint.alarms:
            guard var editor = alarmEditor else { return }
            let out = editor.receive(payload, now: clock())
            alarmEditor = editor
            performAlarm(out)
        case ZeppEndpoint.connection:
            // §3.5: a ping `03` is answered `04` on the same endpoint.
            if payload == [0x03] { send(ZeppEndpoint.connection, [0x04]) }
        case ZeppEndpoint.activityFetch:
            // Path B replies (§6.1). The app drives Path A, so this only arrives if the strap answers there.
            guard var fetch else { return }
            lastFetchProgressAt = clock()
            let actions = fetch.receiveControl(payload)
            self.fetch = fetch
            perform(actions)
        default:
            break
        }
    }

    private func handleConfig(_ payload: [UInt8]) {
        switch currentStep {
        case .healthConfig?:
            if let reply = ZeppConfig.parseReadReply(payload), reply.group == ZeppConfig.healthGroup {
                recordingWarnings = Self.recordingWarnings(ZeppHealthSettings(reply))
                helioLog.notice("helio: HEALTH reply read, \(self.recordingWarnings.count, privacy: .public) recording warning(s)")
            } else {
                helioLog.notice("helio: HEALTH reply unreadable; no recording warnings")
            }
            advance(from: .healthConfig)
        case .alertCapabilities?:
            configCapabilities = ZeppConfigCapabilities.parse(payload)
            advance(from: .alertCapabilities)
        case .alertSettings?:
            let reply = ZeppConfig.parseReadReply(payload)
            hapticAlerts = ZeppHapticAlertSettings(capabilities: controlCapabilities,
                                                   configCapabilities: configCapabilities, healthReply: reply)
            advance(from: .alertSettings)
        default:
            break
        }
    }

    // MARK: History fetch (§6), decisions 8, 10

    private func startFetch() {
        guard let sink else { return finishFetch(interrupted: true) }
        let now = clock()
        let plan = HelioFetchPlan.plan(cursors: sink.fetchCursors(timeline: timeline), now: now,
                                       notBefore: sink.notBefore(timeline: timeline, now: now))
        sink.beginSync(timeline: timeline, now: now)
        syncCounts = (0, 0, 0)
        var machine = ZeppHistoryFetch(plan: plan, now: now, configuration: .init(ackPolicy: Self.ackPolicy))
        let actions = machine.start()
        fetch = machine
        lastFetchProgressAt = now
        perform(actions)
    }

    private func perform(_ actions: [ZeppHistoryFetch.Action]) {
        for action in actions {
            switch action {
            case .sendControl(let bytes):
                if bytes.count == 2, bytes[0] == ZeppFetchCommand.ackMarker { fetchAcksSent.append(bytes[1]) }
                transport?.write(ZeppWrite(.activityControl, bytes))
            case .roundReady(let round):
                let durable = sink?.persist(round, timeline: timeline, now: clock()) ?? false
                if durable { syncCounts.stored += 1 } else { syncCounts.failed += 1 }
                helioLog.notice("helio: round \(round.type.displayName, privacy: .public) \(round.parsed.records.count) record(s) \(durable ? "stored" : "NOT stored", privacy: .public); ack 03 09")
                guard var machine = fetch else { continue }
                let next = machine.commit(roundID: round.id, durable: durable)
                fetch = machine
                perform(next)
            case .roundFailed(let type, let failure):
                syncCounts.failed += 1
                helioLog.error("helio: round \(type.displayName, privacy: .public) failed (\(String(describing: failure), privacy: .public))")
            case .noData:
                syncCounts.empty += 1
            case .finished:
                finishFetch(interrupted: false)
            }
        }
    }

    private func finishFetch(interrupted: Bool) {
        guard phase == .syncing || fetch != nil else { return }
        fetch = nil
        pendingNotify.subtract([.activityControl, .activityData])
        if isLinkConnected {
            transport?.setNotify(.activityControl, enabled: false)
            transport?.setNotify(.activityData, enabled: false)
        }
        var result = sink?.finishSync(timeline: timeline, now: clock()) ?? HelioSyncResult()
        result.roundsStored = syncCounts.stored
        result.roundsFailed = syncCounts.failed
        result.typesEmpty = syncCounts.empty
        result.interrupted = interrupted
        result.identity = identity
        let now = clock()
        lastSyncResult = result
        if let today = result.todaySteps { steps = today }
        if !interrupted { lastSyncAt = now }
        if phase == .syncing { phase = .ready }
        syncStatus = Self.status(for: result)
        helioLog.notice("helio: sync finished: \(result.roundsStored, privacy: .public) stored, \(result.roundsFailed, privacy: .public) failed, \(result.typesEmpty, privacy: .public) empty, \(result.nights.count, privacy: .public) night(s)\(interrupted ? ", interrupted" : "", privacy: .public)")
        if isLinkConnected, services?.contains(ZeppEndpoint.battery) == true {
            send(ZeppEndpoint.battery, ZeppBatteryStatus.request)
        }
        let timeline = self.timeline
        Task { @MainActor in await self.onSyncFinished(result, timeline) }
    }

    /// Plain-language warnings for the HEALTH switches that stop the strap RECORDING something
    /// (§5.5), off only when the strap reported them off (unknown is not off). HEALTH `0x04` ("Active
    /// HR monitoring") is a sampling boost during activity, not a recording switch, so it is never a
    /// warning; neither is heart-rate sharing, which only affects live broadcast without a key.
    static func recordingWarnings(_ settings: ZeppHealthSettings) -> [String] {
        var out: [String] = []
        if settings.heartRateMonitoring == 0x00 {
            out.append("All-day heart rate is off, so heart rate, resting heart rate and HRV history may be missing.")
        }
        if settings.highAccuracySleep == false {
            out.append("High-accuracy sleep monitoring is off, so sleep stages may be missing.")
        }
        if settings.sleepBreathingQuality == false {
            out.append("Sleep breathing quality is off, so sleep respiratory rate may be missing.")
        }
        if settings.stressMonitoring == false { out.append("Stress monitoring is off, so stress will be empty.") }
        if settings.allDaySpO2 == false { out.append("All-day SpO₂ is off, so automatic SpO₂ readings will be empty.") }
        return out
    }

    static func status(for result: HelioSyncResult) -> String {
        if result.interrupted { return "Sync interrupted: what arrived is saved, the rest stays on the strap" }
        if result.roundsFailed > 0 { return "Synced with \(result.roundsFailed) failed round(s); they stay on the strap for next time" }
        return result.roundsStored == 0 ? "Up to date" : "Synced"
    }

    // MARK: Live heart rate (§7.1)

    /// Tier 0 (decision 7): listen to standard heart rate without auth. Shown only if it arrives.
    private func startTierZero() {
        guard let transport, transport.has(.heartRateMeasurement), transport.canNotify(.heartRateMeasurement) else { return }
        transport.setNotify(.heartRateMeasurement, enabled: true)
    }

    /// The authenticated stream: start, then `04 02` every second, stop after `duration`.
    func startLiveHeartRate(duration: TimeInterval = 60) {
        guard canStreamHeartRate, !liveHeartRateRunning, let transport else { return }
        // A new measurement shows only its own readings (decision 30), never the last one's.
        liveHR = nil
        liveHRAt = nil
        transport.setNotify(.heartRateMeasurement, enabled: true)
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
        let now = clock()
        liveHRKeepAliveAt = now.addingTimeInterval(1)
        liveHREndsAt = now.addingTimeInterval(duration)
        liveHeartRateRunning = true
        liveHeartRateOwner = .measure
    }

    /// A workout's stream (#227): the same start and 1 s `04 02` keep-alive, with no time limit, until
    /// `stopWorkoutHeartRate()` (or the link drops). A running Measure is taken over, not restarted.
    // SPEC-GAP: §7.1 gives no maximum stream duration; none is applied here (see
    // `workoutStreamRestartAfter` for a strap that stops by itself).
    func startWorkoutHeartRate() {
        guard canStreamHeartRate, let transport else { return }
        let now = clock()
        if liveHeartRateRunning {
            liveHeartRateOwner = .workout
            liveHREndsAt = nil
            liveHRStartedAt = now
            return
        }
        transport.setNotify(.heartRateMeasurement, enabled: true)
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
        liveHRKeepAliveAt = now.addingTimeInterval(1)
        liveHREndsAt = nil
        liveHRStartedAt = now
        liveHeartRateRunning = true
        liveHeartRateOwner = .workout
    }

    /// Stops the stream only if a workout owns it.
    func stopWorkoutHeartRate() {
        guard liveHeartRateOwner == .workout else { return }
        stopLiveHeartRate()
    }

    func stopLiveHeartRate() {
        guard liveHeartRateRunning else { return }
        liveHeartRateRunning = false
        liveHeartRateOwner = nil
        liveHRKeepAliveAt = nil
        liveHREndsAt = nil
        liveHRStartedAt = nil
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
        transport?.setNotify(.heartRateMeasurement, enabled: false)
    }

    // MARK: Find my strap and buzz (§11, §13.2), decisions 18, 19, 22

    /// Starts "find device". Stops by itself after 60 s. nil on success, else why it didn't start.
    @discardableResult
    func startFind() -> String? {
        do {
            let out = try findState.machine.start(now: clock())
            helioLog.notice("helio: find START")
            performFind(out)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    func stopFind() {
        guard findState.machine.isBuzzing else { return }
        helioLog.notice("helio: find STOP (user or screen left)")
        performFind(findState.machine.stop())
    }

    /// One short buzz (2 s): find start, then stop.
    @discardableResult
    func buzz() -> String? {
        do {
            let out = try findState.machine.buzz(now: clock())
            helioLog.notice("helio: buzz")
            performFind(out)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    private func performFind(_ out: ZeppFindDevice.Output) {
        send(out.messages)
        findPhase = findState.machine.state
        for event in out.events {
            switch event {
            case .capabilities(let version):
                findVersion = version
                advance(from: .findCapabilities)
            case .stopped(let reason):
                helioLog.notice("helio: find stopped (\(String(describing: reason), privacy: .public))")
            case .owedStopSent:
                helioLog.notice("helio: sent the find stop owed since the link dropped")
            default:
                break
            }
        }
    }

    // MARK: Alarms (§12, §15.2), decision 20

    /// Re-reads the strap's list. Read-only.
    func readAlarms() {
        guard var editor = alarmEditor else { return }
        do {
            let out = try editor.read(now: clock())
            alarmEditor = editor
            performAlarm(out)
        } catch {
            alarmNotice = Self.describe(error)
        }
    }

    /// A new alarm in the lowest free slot. nil when the write went out.
    @discardableResult
    func addAlarm(hour: UInt8, minute: UInt8, days: ZeppAlarmDays) -> String? {
        editAlarm { try $0.add(hour: hour, minute: minute, days: days, isEnabled: true, now: self.clock()) }
    }

    /// Replaces one slot (an edit, or enable/disable).
    @discardableResult
    func replaceAlarm(_ alarm: ZeppAlarm) -> String? {
        editAlarm { try $0.replace(alarm, now: self.clock()) }
    }

    @discardableResult
    func deleteAlarm(slot: UInt8) -> String? {
        editAlarm { try $0.delete(slot: slot, now: self.clock()) }
    }

    private func editAlarm(_ body: (inout ZeppAlarmEditor) throws -> ZeppAlarmEditor.Output) -> String? {
        guard var editor = alarmEditor else { return "Alarms aren't available on this connection." }
        do {
            let out = try body(&editor)
            alarmEditor = editor
            alarmNotice = "Saving to the strap…"
            performAlarm(out)
            return nil
        } catch {
            let reason = Self.describe(error)
            alarmNotice = reason
            return reason
        }
    }

    private func performAlarm(_ out: ZeppAlarmEditor.Output) {
        send(out.messages)
        for event in out.events {
            switch event {
            case .listRead(let alarms):
                helioLog.notice("helio: alarm list read, \(alarms.count, privacy: .public) alarm(s)")
                advance(from: .alarms)
            case .listUnreadable(let error):
                alarmNotice = "Couldn't read the strap's alarms."
                helioLog.error("helio: alarm list unreadable (\(String(describing: error), privacy: .public))")
                advance(from: .alarms)
            case .changedOnStrap:
                alarmNotice = "The strap's alarms changed. Reading them again."
                readAlarms()
            case .writeAcknowledged(let write):
                helioLog.notice("helio: alarm slot \(write.slot, privacy: .public) acknowledged; reading back")
            case .writeFailed(let write, let failure):
                alarmNotice = "The strap didn't confirm the change. Nothing was retried."
                helioLog.error("helio: alarm slot \(write.slot, privacy: .public) write failed (\(String(describing: failure), privacy: .public))")
            case .writeChecked(let check):
                alarmNotice = check.slotMatches && check.otherSlotsUnchanged
                    ? "Saved on the strap."
                    : "The strap's list doesn't match what was saved. Check it below."
                helioLog.notice("helio: alarm slot \(check.write.slot, privacy: .public) re-read: matches \(check.slotMatches, privacy: .public), others unchanged \(check.otherSlotsUnchanged, privacy: .public)")
            case .writeUnverified:
                alarmNotice = "Saved, but the strap's list couldn't be read back."
            }
        }
    }

    // MARK: Plain-language errors

    static func describe(_ error: Error) -> String {
        switch error {
        case ZeppControlError.unsupported:
            return "The strap didn't report support for this on this connection."
        case ZeppFindDevice.Error.alreadyActive:
            return "The strap is already vibrating."
        case let error as ZeppAlarmEditor.Error:
            switch error {
            case .busy: return "Another alarm change is still in progress."
            case .listMalformedThisConnection: return "The strap's alarm list couldn't be read on this connection."
            case .listNotRead: return "The alarm list hasn't been read yet."
            case .listChangedOnStrap: return "The strap's alarms changed. Review them and try again."
            case .timeNotSet: return "The strap's clock wasn't confirmed on this connection, so alarms can't be edited."
            case .noFreeSlot: return "The strap already has 10 alarms."
            case .slotEmpty: return "That alarm is no longer on the strap."
            case .smartWakeNotOffered: return "Smart wake can't be changed in this version."
            case .invalidAlarm: return "That time isn't valid."
            }
        default:
            return "That didn't work."
        }
    }
}
