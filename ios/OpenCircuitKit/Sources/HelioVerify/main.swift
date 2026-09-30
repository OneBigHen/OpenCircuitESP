// HelioVerify — macOS CoreBluetooth check against a real Amazfit Helio Strap / Ring (#215).
//
// Thin glue only: it moves bytes between CoreBluetooth and ZeppKit's pure state machines
// (`ZeppLink`, `ZeppHistoryFetch`) and prints what they decide. The auth key is never printed or
// logged, nor is the strap's serial number. The history fetch acks `03 09` (keep on strap) unless
// `--allow-delete` AND `--out` are both given; then a round is delete-acked only after its raw
// bytes are written and fsynced to the `--out` file.

import CoreBluetooth
import Foundation
import ZeppKit

// MARK: - Options

struct Options {
    var keyFile: String?
    var allowDelete = false
    var outPath: String?
    var name: String?
    var scanSeconds: Double = 30
    var hrSeconds = 15
    var sinceHours: Double = 24
    var types: [ZeppFetchType] = [.activity, .hrv, .spo2, .temperature, .restingHeartRate,
                                  .sleepRespiratoryRate, .sleepSession]
    var setTime = false
    var timeoutSeconds: Double = 300
}

let usage = """
HelioVerify — check an Amazfit Helio Strap / Ring over Bluetooth LE (macOS).

USAGE
  swift run HelioVerify [options]

Without a key: scans, connects, reads the standard battery level (if the strap exposes 0x2A19)
and firmware/hardware revision, and listens to standard heart-rate notifications (0x2A37; needs
Zepp's "Heart Rate Push" switch on).

With --key-file: also authenticates, reads battery over the encrypted battery endpoint, reads the
HEALTH settings (warns about switches that stop recording), streams live HR, and runs a
NON-DESTRUCTIVE history fetch (ack 03 09: the strap keeps everything), printing summaries.

OPTIONS
  --key-file <path>   File holding the 16-byte auth key as 32 hex digits (optional 0x prefix).
                      The key is never printed or logged.
  --types <list>      Comma-separated fetch types in hex (default 01,49,25,2e,3a,38,48).
                      Known: 01 02 0d 12 13 25 26 2e 38 3a 3d 48 49.
  --since-hours <h>   Fetch history from this many hours ago (default 24).
  --hr-seconds <n>    How long to listen to live HR (default 15; 0 skips it).
  --name <name>       Only connect to a device advertising exactly this name.
  --scan-seconds <n>  Give up scanning after n seconds (default 30).
  --timeout <n>       Abort the whole run after n seconds (default 300).
  --set-time          Set the strap's clock to this Mac's time before fetching (off by default).
  --out <path>        Append each fetched round (raw hex + metadata, JSON lines) to this file and
                      fsync it. The file holds REAL HEALTH DATA: keep it out of git.
  --allow-delete      DESTRUCTIVE. Ack 03 01 ("saved, drop it from the strap") for each round,
                      but only after it is durably written to --out. Requires --key-file and --out.
  --help              Show this help.

EXIT CODES
  0 ok · 1 usage · 2 Bluetooth unavailable · 3 timeout · 4 auth failed · 5 no device found
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) needs a value") }
        return args[i]
    }
    func number(_ flag: String) -> Double {
        guard let n = Double(value(flag)), n >= 0 else { fail("\(flag) needs a non-negative number") }
        return n
    }
    while i < args.count {
        switch args[i] {
        case "--help", "-h":
            print(usage)
            exit(0)
        case "--key-file": o.keyFile = value("--key-file")
        case "--allow-delete": o.allowDelete = true
        case "--out": o.outPath = value("--out")
        case "--name": o.name = value("--name")
        case "--scan-seconds": o.scanSeconds = number("--scan-seconds")
        case "--hr-seconds": o.hrSeconds = Int(number("--hr-seconds"))
        case "--since-hours": o.sinceHours = number("--since-hours")
        case "--timeout": o.timeoutSeconds = number("--timeout")
        case "--set-time": o.setTime = true
        case "--types":
            let list = value("--types").split(separator: ",")
            o.types = list.map { code in
                let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
                let digits = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
                guard let raw = UInt8(digits, radix: 16), let type = ZeppFetchType(rawValue: raw) else {
                    fail("unknown fetch type '\(code)'")
                }
                return type
            }
        default:
            fail("unknown option '\(args[i])' (see --help)")
        }
        i += 1
    }
    if o.allowDelete && (o.keyFile == nil || o.outPath == nil) {
        fail("--allow-delete requires --key-file and --out: data is only dropped from the strap after it is durably saved")
    }
    return o
}

/// Reads and parses the key file. Never echoes its contents, even on error.
func loadKey(_ path: String) -> ZeppAuthKey {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { fail("cannot read --key-file") }
    guard let key = ZeppAuthKey(hex: text) else {
        fail("--key-file must hold exactly 32 hex digits (optionally 0x-prefixed); contents not shown")
    }
    return key
}

// MARK: - Verifier

@available(macOS 10.15.4, *)
final class HelioVerifier: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum Step: String {
        case scanning, connecting, discovering, readingBasics, liveHR, enablingChunked, authenticating,
             servicesList, battery, setTime, config, authedHR, enablingFetch, fetching, done
    }

    let options: Options
    let key: ZeppAuthKey?
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var characteristics: [ZeppCharacteristic: CBCharacteristic] = [:]
    var step = Step.scanning
    var pendingServices = 0
    var pendingReads = Set<ZeppCharacteristic>()
    var pendingNotify = Set<ZeppCharacteristic>()
    var link: ZeppLink?
    var services: ZeppServicesList?
    var fetch: ZeppHistoryFetch?
    var writeQueue: [ZeppWrite] = []
    var hrTimer: Timer?
    var outHandle: FileHandle?
    var roundsDelivered = 0
    var isFinishing = false

    init(options: Options, key: ZeppAuthKey?) {
        self.options = options
        self.key = key
        super.init()
        if let path = options.outPath {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { fail("cannot open --out for writing") }
            handle.seekToEndOfFile()
            outHandle = handle
        }
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeoutSeconds) { [weak self] in
            self?.finish("timed out in step '\(self?.step.rawValue ?? "?")'", code: 3)
        }
    }

    func log(_ message: String) { print(message) }

    func finish(_ message: String? = nil, code: Int32 = 0) {
        guard !isFinishing else { return }
        isFinishing = true
        if let message { log(code == 0 ? message : "FAILED: \(message)") }
        hrTimer?.invalidate()
        if var fetch, fetch.phase != .finished && fetch.phase != .idle {
            // Never leave the strap mid-round; the abort ack is always 03 09 (keep).
            perform(fetch.abort())
            self.fetch = fetch
        }
        try? outHandle?.close()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("scanning for Amazfit Helio devices…")
            central.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + options.scanSeconds) { [weak self] in
                guard let self, self.step == .scanning else { return }
                self.finish("no Amazfit Helio device found in \(Int(self.options.scanSeconds)) s", code: 5)
            }
        case .unauthorized:
            finish("Bluetooth permission denied: allow your terminal in System Settings › Privacy & Security › Bluetooth", code: 2)
        case .poweredOff, .unsupported:
            finish("Bluetooth is off or unsupported", code: 2)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard step == .scanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard let model = ZeppDeviceModel.match(advertisedName: name) else { return }
        if let wanted = options.name, wanted != name { return }
        log("found \(model.rawValue) (\"\(name)\", RSSI \(RSSI)); connecting")
        central.stopScan()
        step = .connecting
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        step = .discovering
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish("connect failed: \(error?.localizedDescription ?? "unknown")", code: 3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard step != .done else { return }
        finish("disconnected in step '\(step.rawValue)': \(error?.localizedDescription ?? "no error")", code: 3)
    }

    // MARK: Discovery

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let found = peripheral.services ?? []
        pendingServices = found.count
        for service in found { peripheral.discoverCharacteristics(nil, for: service) }
        if found.isEmpty { finish("no GATT services", code: 3) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            // Discover by UUID across ALL services (§2).
            for known in ZeppCharacteristic.allCases where CBUUID(string: known.uuidString) == characteristic.uuid {
                characteristics[known] = characteristic
            }
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        let names = ZeppCharacteristic.allCases.filter { characteristics[$0] != nil }.map(\.rawValue)
        log("characteristics found: \(names.joined(separator: ", "))")
        readBasics()
    }

    // MARK: Unauthenticated basics

    func readBasics() {
        step = .readingBasics
        for wanted in [ZeppCharacteristic.batteryLevel, .firmwareRevision, .hardwareRevision] {
            if let c = characteristics[wanted] {
                pendingReads.insert(wanted)
                peripheral?.readValue(for: c)
            }
        }
        if characteristics[.batteryLevel] == nil { log("battery: 0x2A19 not exposed (use the battery endpoint after auth)") }
        if pendingReads.isEmpty { afterBasics() }
    }

    func afterBasics() {
        if key != nil {
            enableChunked()
        } else {
            listenToStandardHR(then: { [weak self] in self?.finish("done (no key: history fetch skipped)") })
        }
    }

    func listenToStandardHR(then next: @escaping () -> Void) {
        guard options.hrSeconds > 0, let c = characteristics[.heartRateMeasurement] else {
            if characteristics[.heartRateMeasurement] == nil { log("live HR: 0x2A37 not exposed") }
            next()
            return
        }
        step = step == .readingBasics ? .liveHR : .authedHR
        log("listening to live HR for \(options.hrSeconds) s…")
        peripheral?.setNotifyValue(true, for: c)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(options.hrSeconds)) { [weak self] in
            self?.peripheral?.setNotifyValue(false, for: c)
            next()
        }
    }

    // MARK: Authenticated session

    func enableChunked() {
        guard let key, let read = characteristics[.chunkedRead], characteristics[.chunkedWrite] != nil else {
            finish("chunked characteristics …0016/…0017 not found", code: 3)
            return
        }
        step = .enablingChunked
        var newLink = ZeppLink(authKey: key)
        if let peripheral { newLink.setMaxWriteLength(peripheral.maximumWriteValueLength(for: .withoutResponse)) }
        link = newLink
        pendingNotify = [.chunkedRead]
        peripheral?.setNotifyValue(true, for: read)
        if let write = characteristics[.chunkedWrite], write.properties.contains(.notify) {
            pendingNotify.insert(.chunkedWrite)
            peripheral?.setNotifyValue(true, for: write)
        }
    }

    func startAuth() {
        step = .authenticating
        log("authenticating…")
        guard var link else { return }
        let out = link.startAuthentication()
        self.link = link
        handle(out)
    }

    func send(_ endpoint: UInt16, _ payload: [UInt8]) {
        guard var link else { return }
        do {
            let writes = try link.send(endpoint: endpoint, payload: payload)
            self.link = link
            enqueue(writes)
        } catch {
            finish("cannot send to endpoint 0x\(String(format: "%04x", endpoint)): \(error)", code: 3)
        }
    }

    func handle(_ out: ZeppLink.Output) {
        enqueue(out.writes)
        for event in out.events {
            switch event {
            case .authenticated:
                log("authenticated")
                step = .servicesList
                send(ZeppEndpoint.servicesList, ZeppServicesList.request)
            case .authenticationFailed(.wrongAuthKey):
                finish("the strap rejected the key (10 05 25): re-extract it (unpairing in Zepp or a reset invalidates it)", code: 4)
            case .authenticationFailed(let failure):
                finish("authentication failed: \(failure) (another central, e.g. the Zepp app, may hold the strap)", code: 4)
            case .message(let message):
                handleMessage(message)
            case .droppedChunk(let reason):
                log("dropped chunk: \(reason)")
            case .undecryptable(let endpoint):
                log("could not decrypt a message on endpoint 0x\(String(format: "%04x", endpoint))")
            case .deviceChunkAck:
                break
            }
        }
    }

    func handleMessage(_ message: ZeppMessage) {
        if message.wasEncrypted, message.trailerCRCMatches != nil {
            log("  (encrypted reply on 0x\(String(format: "%04x", message.endpoint)): device trailer CRC \(message.trailerCRCMatches == true ? "matches" : "does NOT match") our layout)")
        }
        switch (step, message.endpoint) {
        case (.servicesList, ZeppEndpoint.servicesList):
            guard let list = ZeppServicesList.parse(message.payload) else {
                finish("malformed services list", code: 3)
                return
            }
            services = list
            link?.apply(servicesList: list)
            let described = list.entries.map { e in
                String(format: "%04x", e.endpoint) + (e.encrypted == true ? "*" : "")
            }
            log("services (* = encrypted): \(described.joined(separator: " "))")
            guard list.contains(ZeppEndpoint.battery) else {
                log("battery (endpoint): 0x0029 not in the services list; skipped")
                return afterBattery()
            }
            step = .battery
            send(ZeppEndpoint.battery, ZeppBatteryStatus.request)
        case (.battery, ZeppEndpoint.battery):
            if let battery = ZeppBatteryStatus.parse(message.payload) {
                let charging = battery.isCharging.map { $0 ? "charging" : "not charging" } ?? "charging state unknown"
                log("battery (endpoint): \(battery.level) %, \(charging)")
            } else {
                log("battery (endpoint): unparseable reply")
            }
            afterBattery()
        case (.setTime, ZeppEndpoint.time):
            log(ZeppTimeCommand.isSuccessReply(message.payload) ? "time set" : "time set: unexpected reply")
            readConfig()
        case (.config, ZeppEndpoint.config):
            if let reply = ZeppConfig.parseReadReply(message.payload) {
                let settings = ZeppHealthSettings(reply)
                log("HEALTH settings (group version \(reply.groupVersion))\(reply.isPartial ? ", partial" : "")")
                for warning in settings.warnings { log("  WARNING: \(warning)") }
                if settings.warnings.isEmpty { log("  no recording switch reported off") }
            } else {
                log("HEALTH settings: unreadable reply")
            }
            startAuthedHR()
        case (_, ZeppEndpoint.heartRate):
            if let event = ZeppHeartRateControl.parse(message.payload) { log("HR endpoint: \(event)") }
        case (.fetching, ZeppEndpoint.activityFetch):
            feedFetchControl(message.payload)
        default:
            log("message on endpoint 0x\(String(format: "%04x", message.endpoint)) (\(message.payload.count) B) ignored in step '\(step.rawValue)'")
        }
    }

    func afterBattery() {
        guard options.setTime else { return readConfig() }
        step = .setTime
        let now = Date()
        if services?.contains(ZeppEndpoint.time) == true {
            send(ZeppEndpoint.time, ZeppTimeCommand.setTime(now, timeZone: .current))
        } else if let c = characteristics[.currentTime] {
            write(ZeppWrite(.currentTime, ZeppTimeCommand.currentTimeBytes(now, timeZone: .current)), to: c)
            log("time set via 0x2A2B")
            readConfig()
        } else {
            log("time set: no time endpoint and no 0x2A2B; skipped")
            readConfig()
        }
    }

    func readConfig() {
        guard services?.contains(ZeppEndpoint.config) == true else {
            log("HEALTH settings: config endpoint 0x000A not in the services list; skipped")
            return startAuthedHR()
        }
        step = .config
        send(ZeppEndpoint.config, ZeppConfig.readRequest(group: ZeppConfig.healthGroup,
                                                          arguments: ZeppConfig.recordingArguments))
    }

    func startAuthedHR() {
        step = .authedHR
        guard options.hrSeconds > 0, characteristics[.heartRateMeasurement] != nil else { return enableFetch() }
        guard services?.contains(ZeppEndpoint.heartRate) == true else {
            log("HR endpoint 0x001D not in the services list; listening to 0x2A37 without starting it")
            return listenToStandardHR { [weak self] in self?.enableFetch() }
        }
        send(ZeppEndpoint.heartRate, ZeppHeartRateControl.start)
        hrTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.send(ZeppEndpoint.heartRate, ZeppHeartRateControl.keepRunning)
        }
        listenToStandardHR { [weak self] in
            guard let self else { return }
            self.hrTimer?.invalidate()
            self.send(ZeppEndpoint.heartRate, ZeppHeartRateControl.stop)
            self.enableFetch()
        }
    }

    // MARK: History fetch (Path A: …0004 / …0005)

    func enableFetch() {
        guard let control = characteristics[.activityControl], let data = characteristics[.activityData] else {
            finish("activity characteristics …0004/…0005 not found (Path B is not wired in HelioVerify)", code: 3)
            return
        }
        step = .enablingFetch
        pendingNotify = [.activityControl, .activityData]
        peripheral?.setNotifyValue(true, for: control)
        peripheral?.setNotifyValue(true, for: data)
    }

    func startFetch() {
        step = .fetching
        let now = Date()
        let since = Date(timeIntervalSince1970: floor((now.timeIntervalSince1970 - options.sinceHours * 3600) / 60) * 60)
        let policy: ZeppAckPolicy = options.allowDelete ? .deleteAfterDurableCommit : .keepOnDevice
        log("fetching \(options.types.map(\.displayName).joined(separator: ", ")) since \(ZeppRoundSummary.iso(since)); ack policy: \(policy == .keepOnDevice ? "KEEP on strap (03 09)" : "delete after durable write (03 01)")")
        var machine = ZeppHistoryFetch(plan: options.types.map { ($0, since) }, now: now,
                                       configuration: .init(ackPolicy: policy))
        let actions = machine.start()
        fetch = machine
        perform(actions)
    }

    func feedFetchControl(_ bytes: [UInt8]) {
        guard var machine = fetch else { return }
        let actions = machine.receiveControl(bytes)
        fetch = machine
        perform(actions)
    }

    func perform(_ actions: [ZeppHistoryFetch.Action]) {
        for action in actions {
            switch action {
            case .sendControl(let bytes):
                if let c = characteristics[.activityControl] { write(ZeppWrite(.activityControl, bytes), to: c) }
            case .roundReady(let round):
                roundsDelivered += 1
                log("  " + ZeppRoundSummary.describe(round))
                let durable = persist(round)
                guard var machine = fetch else { continue }
                let next = machine.commit(roundID: round.id, durable: durable)
                fetch = machine
                perform(next)
            case .roundFailed(let type, let failure):
                log("  \(type.displayName): round failed (\(failure)); acked 03 09 where a round was open")
            case .noData(let type):
                log("  \(type.displayName): nothing since the cursor")
            case .finished:
                disableFetchNotifications()
                step = .done
                finish("done: \(roundsDelivered) round(s) fetched")
            }
        }
    }

    /// Appends the round to --out and fsyncs. Returns true only when that succeeded.
    func persist(_ round: ZeppFetchRound) -> Bool {
        guard let handle = outHandle else { return false }
        let line: [String: Any] = [
            "type": String(format: "%02x", round.type.rawValue),
            "since": round.since.timeIntervalSince1970,
            "start": round.start.timeIntervalSince1970,
            "crcVerified": round.crcVerified,
            "dataHex": ZeppHex.string(round.rawData),
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            return true
        } catch {
            log("  could not persist the round (\(error)); it stays on the strap")
            return false
        }
    }

    func disableFetchNotifications() {
        for wanted in [ZeppCharacteristic.activityControl, .activityData] {
            if let c = characteristics[wanted] { peripheral?.setNotifyValue(false, for: c) }
        }
    }

    // MARK: Writes (queued for write-without-response flow control)

    func enqueue(_ writes: [ZeppWrite]) {
        for w in writes {
            guard let c = characteristics[w.characteristic] else { continue }
            write(w, to: c)
        }
    }

    func write(_ w: ZeppWrite, to c: CBCharacteristic) {
        writeQueue.append(w)
        flushWrites()
    }

    // SPEC-GAP: which write types `…0016` and `…0004` accept is a §10 capture item; write without
    // response when the characteristic offers it, else with response.
    func flushWrites() {
        guard let peripheral else { return }
        while let next = writeQueue.first, let c = characteristics[next.characteristic] {
            let withoutResponse = c.properties.contains(.writeWithoutResponse)
            if withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            writeQueue.removeFirst()
            peripheral.writeValue(Data(next.bytes), for: c, type: withoutResponse ? .withoutResponse : .withResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWrites()
    }

    // MARK: Notifications and reads

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let which = known(characteristic), pendingNotify.contains(which) else { return }
        if let error {
            finish("enabling notifications on \(which.rawValue) failed: \(error.localizedDescription)", code: 3)
            return
        }
        pendingNotify.remove(which)
        guard pendingNotify.isEmpty else { return }
        switch step {
        case .enablingChunked: startAuth()
        case .enablingFetch: startFetch()
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let which = known(characteristic) else { return }
        defer {
            if step == .readingBasics, pendingReads.remove(which) != nil, pendingReads.isEmpty { afterBasics() }
        }
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        switch which {
        case .batteryLevel:
            if let level = ZeppBatteryLevelCharacteristic.parse(bytes) { log("battery (0x2A19): \(level) %") }
        case .firmwareRevision:
            log("firmware: \(String(decoding: bytes, as: UTF8.self))")
        case .hardwareRevision:
            log("hardware: \(String(decoding: bytes, as: UTF8.self))")
        case .heartRateMeasurement:
            if let hr = ZeppHeartRateMeasurement.parse(bytes) {
                let rr = hr.rrIntervals.isEmpty ? "" : ", \(hr.rrIntervals.count) RR interval(s)"
                log("  live HR: \(hr.beatsPerMinute) bpm\(rr)")
            }
        case .chunkedRead, .chunkedWrite:
            guard var link else { return }
            let out = link.receive(bytes)
            self.link = link
            handle(out)
        case .activityControl:
            feedFetchControl(bytes)
        case .activityData:
            guard var machine = fetch else { return }
            let actions = machine.receiveData(bytes)
            fetch = machine
            perform(actions)
        case .currentTime:
            break
        }
    }

    func known(_ characteristic: CBCharacteristic) -> ZeppCharacteristic? {
        characteristics.first { $0.value === characteristic }?.key
    }
}

// MARK: - Main

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let key = options.keyFile.map(loadKey)
if options.allowDelete {
    print("WARNING: --allow-delete: rounds durably written to --out will be DROPPED from the strap (ack 03 01).")
}
if #available(macOS 10.15.4, *) {
    let verifier = HelioVerifier(options: options, key: key)
    withExtendedLifetime(verifier) { dispatchMain() }
} else {
    fail("HelioVerify needs macOS 10.15.4 or newer")
}
