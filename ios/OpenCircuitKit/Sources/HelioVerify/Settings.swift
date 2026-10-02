// HelioVerify strap settings (#228, #229, #230): a read-only look at the config groups, ONE setting
// changed through the app's own write path (`ZeppSettingsEditor`, ZEPP_PROTOCOL.md §17.8), and
// §10 item 25's three rejection probes.
//
// `--set-config` decides nothing here: ZeppKit's editor reads the setting and its parent, validates,
// writes one entry and re-reads, exactly as the app does. The probes are the only raw config writes
// in the repository, on purpose: each sends something the editor refuses, so that one sitting with
// a real strap records what a rejection looks like (§17.4). Each is gated by `--allow-write`, one per
// run, and writes the strap's previous value back if the strap took it.

import CoreBluetooth
import Foundation
import ZeppKit

/// One step of `--settings` / `--set-config` / `--config-probe`, run in this order.
enum SettingsStep: Equatable {
    case capabilities
    case rawGroups
    case editorRead
    case change
    case probe
}

/// A running rejection probe.
struct ProbeRun: Equatable {
    enum Phase: Equatable { case awaitingAck, awaitingReRead, awaitingRestoreAck, awaitingRestoreReRead }

    let probe: ConfigProbe
    let write: [UInt8]
    let reRead: [UInt8]
    /// What to write back if the re-read shows the strap took the probe; nil when nothing is owed.
    let restore: [UInt8]?
    /// The arg the probe wrote, and the value that means "the strap took it".
    let argument: UInt8
    let probeValue: ZeppConfigValue
    var phase: Phase = .awaitingAck
}

@available(macOS 10.15.4, *)
extension HelioVerifier {

    func startSettings() {
        guard controlCapabilities.isSupported(.hapticAlerts) else {
            log("settings: \(describe(controlCapabilities.support(.hapticAlerts))); nothing sent")
            return nextControl()
        }
        settingsEditor = ZeppSettingsEditor(capabilities: controlCapabilities, configCapabilities: configCapabilities)
        var steps: [SettingsStep] = configCapabilities == nil ? [.capabilities] : []
        if options.settings { steps.append(.rawGroups) }
        steps.append(.editorRead)
        if options.setConfig != nil { steps.append(.change) }
        if options.configProbe != nil { steps.append(.probe) }
        settingsSteps = steps
        nextSettingsStep()
    }

    func nextSettingsStep() {
        guard !isFinishing else { return }
        guard !settingsSteps.isEmpty else { return nextControl() }
        switch settingsSteps.removeFirst() {
        case .capabilities:
            log("settings: reading the config capabilities (read-only)")
            beginWait(.settings, timeout: 5) { [weak self] in
                self?.log("settings: no config capabilities reply in 5 s; nothing more sent")
                self?.nextControl()
            }
            sendControl([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: ZeppConfigCapabilities.request)])
        case .rawGroups:
            rawGroupQueue = configCapabilities?.groups ?? []
            nextRawGroup()
        case .editorRead:
            readSettingsWithEditor()
        case .change:
            changeSetting()
        case .probe:
            startProbe()
        }
    }

    /// Every config payload while a settings step runs.
    func receiveSettingsMessage(_ payload: [UInt8]) {
        if payload.first == 0x02, configCapabilities == nil {
            guard let caps = ZeppConfigCapabilities.parse(payload) else {
                log("settings: unparseable config capabilities reply; nothing more sent")
                return nextControl()
            }
            configCapabilities = caps
            settingsEditor?.noteConfigCapabilities(caps)
            log("config: service version \(caps.serviceVersion)\(caps.isVersionUnderstood ? "" : " (NOT understood, > 3)"), "
                + "groups \(caps.groups.map(hex8).joined(separator: " "))")
            return nextSettingsStep()
        }
        if probeRun != nil { return receiveProbeMessage(payload) }
        if let group = rawGroupInFlight { return receiveRawGroup(payload, group: group) }
        guard var editor = settingsEditor else { return }
        let out = editor.receive(payload, now: Date())
        settingsEditor = editor
        performSettings(out)
    }

    func tickSettings() {
        guard var editor = settingsEditor, editor.nextDeadline.map({ Date() >= $0 }) == true else { return }
        let out = editor.tick(now: Date())
        settingsEditor = editor
        performSettings(out)
    }

    // MARK: Read-only: every listed group, codes only (§10 item 25)

    func nextRawGroup() {
        guard !rawGroupQueue.isEmpty else {
            rawGroupInFlight = nil
            return nextSettingsStep()
        }
        let group = rawGroupQueue.removeFirst()
        rawGroupInFlight = group
        beginWait(.settings, timeout: 5) { [weak self] in
            self?.log("config group 0x\(hex8(group)): no reply in 5 s")
            self?.nextRawGroup()
        }
        // Arg count 00 asks for every arg in the group (§17.1). The raw reply is not printed: it
        // holds values; only versions and codes are.
        send(ZeppEndpoint.config, ZeppConfig.readRequest(group: group, arguments: [], includeConstraints: true))
        log("  0x000a → 03 01 \(hex8(group)) 00")
    }

    func receiveRawGroup(_ payload: [UInt8], group: UInt8) {
        guard let reply = ZeppConfig.parseReadReply(payload), reply.group == group else {
            log("config group 0x\(hex8(group)): status not 01 or unreadable (\(payload.count) B, first bytes \(spaced(Array(payload.prefix(3)))))")
            return nextRawGroup()
        }
        let codes = reply.entries.map { "\(hex8($0.argument))(\(typeCode($0.value)))" }.joined(separator: " ")
        log("config group 0x\(hex8(group)) version \(reply.groupVersion), \(reply.entries.count) arg(s) parsed\(reply.isPartial ? " (PARTIAL: an unknown type code stopped parsing; \(payload.count) B in the reply)" : ""): \(codes.isEmpty ? "none" : codes)")
        nextRawGroup()
    }

    func typeCode(_ value: ZeppConfigValue) -> String {
        switch value {
        case .bool: return "0b"
        case .byte: return "10"
        case .byteList: return "11"
        case .short: return "01"
        case .shortList: return "02"
        case .int: return "03"
        case .string: return "20"
        case .hourMinute: return "30"
        case .timestamp: return "40"
        case .unboundedInt: return "50"
        }
    }

    // MARK: The app's path: read, then one change

    func readSettingsWithEditor() {
        guard var editor = settingsEditor else { return nextSettingsStep() }
        let groups = [ZeppConfig.healthGroup, ZeppConfig.workoutGroup].filter { editor.isOffered(group: $0) }
        guard !groups.isEmpty else {
            log("settings: neither HEALTH (08) nor WORKOUT (09) is offered on this connection; nothing sent")
            return nextControl()
        }
        do {
            let out = try editor.read(groups: groups, now: Date())
            settingsEditor = editor
            beginWait(.settings)
            performSettings(out)
        } catch {
            log("settings: not read: \(error)")
            nextControl()
        }
    }

    func changeSetting() {
        guard let (setting, value) = options.setConfig, var editor = settingsEditor else { return nextSettingsStep() }
        guard let current = editor.snapshot.value(setting) else {
            log("set-config: the strap didn't report \(setting.rawValue) with the expected type; nothing written")
            return nextControl()
        }
        do {
            let out = try editor.change(.init(setting: setting, from: current, to: value), now: Date())
            settingsEditor = editor
            log("set-config: WRITING \(setting.rawValue) (group \(hex8(setting.group)) arg \(hex8(setting.argument))): "
                + "\(describe(current, setting)) → \(describe(value, setting)); reading it and its parent first")
            beginWait(.settings)
            performSettings(out)
        } catch {
            log("set-config: nothing written: \(error)")
            nextControl()
        }
    }

    func performSettings(_ out: ZeppSettingsEditor.Output) {
        sendControl(out.messages)
        for event in out.events {
            switch event {
            case .read(let group):
                printSettings(group: group)
            case .readFailed(let group, let failure):
                log("settings: group 0x\(hex8(group)) unreadable (\(failure))")
            case .changedOnStrap(let change, let current):
                log("set-config: \(change.setting.rawValue) changed on the strap since the read (now \(current.map { describe($0, change.setting) } ?? "not reported")); nothing written")
            case .refused(let change, let error):
                log("set-config: \(change.setting.rawValue) refused after the fresh read (\(error)); nothing written")
            case .writeAcknowledged:
                log("set-config: 06 01; reading back")
            case .writeNotAcknowledged(_, let failure):
                log("set-config: the strap did not acknowledge (\(failure)); reading back, not retried")
            case .writeChecked(let check):
                let now = check.readBack.map { describe($0, check.change.setting) } ?? "NOT REPORTED (hidden for this connection)"
                log("set-config: the strap now holds \(now): \(check.tookChange ? "TOOK the change" : "did NOT take the change")"
                    + "\(check.groupVersionChanged ? "; the group version CHANGED, so the group is read-only for this connection" : "")")
            case .writeUnverified(_, let failure, let readFailure):
                log("set-config: \(failure == nil ? "acknowledged" : "not acknowledged"), but the re-read failed (\(readFailure))")
            }
        }
        if controlWait == .settings, settingsEditor?.isBusy == false, probeRun == nil, rawGroupInFlight == nil {
            nextSettingsStep()
        }
    }

    func printSettings(group: UInt8) {
        guard let snapshot = settingsEditor?.snapshot else { return }
        log("settings, group 0x\(hex8(group)) version \(snapshot.groupVersions[group].map(String.init) ?? "?")\(snapshot.isWritable(group: group) ? "" : " (READ-ONLY: a version the spec doesn't describe)"):")
        for setting in ZeppSetting.allCases where setting.group == group {
            guard let value = snapshot.value(setting) else {
                log("  \(setting.rawValue): not reported with the expected type")
                continue
            }
            let allowed = snapshot.entries[setting]?.allowedValues.map { " (allowed: \($0.map { describe(.byte($0), setting) }.joined(separator: ", ")))" } ?? ""
            var state = ""
            if case .needs(let parent) = snapshot.availability(setting) { state = " [inactive: needs \(parent.rawValue)]" }
            log("  \(setting.rawValue): \(describe(value, setting))\(allowed)\(state)")
        }
    }

    func describe(_ value: ZeppConfigValue, _ setting: ZeppSetting) -> String {
        switch (setting, value) {
        case (_, .bool(let on)): return on ? "on" : "off"
        case (.workoutDetectionSensitivity, .byte(let n)): return ["high", "standard", "low"].indices.contains(Int(n)) ? ["high", "standard", "low"][Int(n)] : "0x\(hex8(n))"
        case (_, .byte(0)): return "off"
        case (.heartRateMonitoring, .byte(0xff)): return "smart"
        case (.heartRateMonitoring, .byte(0xfe)): return "continuous"
        case (.heartRateMonitoring, .byte(let n)): return "every \(n) min"
        case (.lowSpO2Alert, .byte(let n)): return "\(n) %"
        case (_, .byte(let n)): return "\(n) bpm"
        default: return "\(value)"
        }
    }

    // MARK: §10 item 25 rejection probes (raw, gated by --allow-write)

    func startProbe() {
        guard let probe = options.configProbe, let snapshot = settingsEditor?.snapshot else { return nextSettingsStep() }
        let group = ZeppConfig.healthGroup
        guard let version = snapshot.groupVersions[group], snapshot.isWritable(group: group) else {
            log("probe: HEALTH wasn't read at a version the spec describes on this connection; nothing written")
            return nextControl()
        }
        let run: ProbeRun
        switch probe {
        case .outsideAllowedList:
            guard case .byte(let current)? = snapshot.value(.highHeartRateAlert),
                  let allowed = snapshot.entries[.highHeartRateAlert]?.allowedValues else {
                log("probe a: the strap didn't report the high-HR alert with allowed values; nothing written")
                return nextControl()
            }
            guard let outside = ([125] + Array(101...200)).first(where: { !allowed.contains($0) }) else {
                log("probe a: every candidate value is allowed; nothing written")
                return nextControl()
            }
            run = ProbeRun(probe: probe, write: [0x05, group, version, 0x00, 0x01, 0x02, 0x10, outside],
                           reRead: [0x03, 0x01, group, 0x01, 0x02],
                           restore: [0x05, group, version, 0x00, 0x01, 0x02, 0x10, current],
                           argument: 0x02, probeValue: .byte(outside))
            log("probe a: high-HR alert is \(current) bpm, allowed \(allowed.map(String.init).joined(separator: " ")); WRITING \(outside) (outside the list)")
        case .childWhileParentOff:
            guard snapshot.isOn(.stressMonitoring) == false, snapshot.isOn(.relaxReminder) == false else {
                log("probe b: needs stress monitoring OFF and the relax reminder OFF (now stress "
                    + "\(snapshot.isOn(.stressMonitoring).map { $0 ? "on" : "off" } ?? "not reported"), relax "
                    + "\(snapshot.isOn(.relaxReminder).map { $0 ? "on" : "off" } ?? "not reported")); skipped, nothing written. "
                    + "Run --set-config stressMonitoring=off first")
                return nextControl()
            }
            run = ProbeRun(probe: probe, write: [0x05, group, version, 0x00, 0x01, 0x14, 0x0b, 0x01],
                           reRead: [0x03, 0x01, group, 0x02, 0x13, 0x14],
                           restore: [0x05, group, version, 0x00, 0x01, 0x14, 0x0b, 0x00],
                           argument: 0x14, probeValue: .bool(true))
            log("probe b: stress monitoring reads off; WRITING the relax reminder on")
        case .versionPlusOne:
            guard let relax = snapshot.isOn(.relaxReminder) else {
                log("probe c: the strap didn't report the relax reminder; nothing written")
                return nextControl()
            }
            // The same value, so whatever the strap does, the setting itself doesn't change.
            run = ProbeRun(probe: probe, write: [0x05, group, version &+ 1, 0x00, 0x01, 0x14, 0x0b, relax ? 0x01 : 0x00],
                           reRead: [0x03, 0x01, group, 0x01, 0x14], restore: nil,
                           argument: 0x14, probeValue: .bool(!relax))
            log("probe c: WRITING the relax reminder's current value (\(relax ? "on" : "off")) with version \(version &+ 1) instead of \(version)")
        }
        probeRun = run
        sendProbe(run.write, phase: .awaitingAck)
    }

    private func sendProbe(_ payload: [UInt8], phase: ProbeRun.Phase) {
        probeRun?.phase = phase
        let awaitingAck = phase == .awaitingAck || phase == .awaitingRestoreAck
        beginWait(.settings, timeout: 5) { [weak self] in
            guard let self, let run = self.probeRun else { return }
            if awaitingAck {
                self.log("probe: NO 06 in 5 s; reading back")
                self.sendProbe(run.reRead, phase: run.phase == .awaitingAck ? .awaitingReRead : .awaitingRestoreReRead)
            } else {
                self.log("probe: no read reply in 5 s")
                self.probeRun = nil
                self.nextControl()
            }
        }
        sendControl([ZeppControlMessage(endpoint: ZeppEndpoint.config, payload: payload)])
    }

    func receiveProbeMessage(_ payload: [UInt8]) {
        guard let run = probeRun else { return }
        log("  0x000a ← \(spaced(payload))")
        switch (run.phase, payload.first) {
        case (.awaitingAck, 0x06?), (.awaitingRestoreAck, 0x06?):
            log("probe: ack status \(payload.count >= 2 ? hex8(payload[1]) : "missing")")
            sendProbe(run.reRead, phase: run.phase == .awaitingAck ? .awaitingReRead : .awaitingRestoreReRead)
        case (.awaitingReRead, 0x04?), (.awaitingRestoreReRead, 0x04?):
            guard let reply = ZeppConfig.parseReadReply(payload) else {
                log("probe: re-read status not 01 or unreadable")
                probeRun = nil
                return nextControl()
            }
            let entry = reply.entries.first { $0.argument == run.argument }
            log("probe: re-read version \(reply.groupVersion), arg \(hex8(run.argument)) = \(entry.map { "\($0.value)" } ?? "MISSING")")
            if run.phase == .awaitingReRead, entry?.value == run.probeValue, let restore = run.restore {
                log("probe: the strap TOOK the probe value; writing the previous value back")
                return sendProbe(restore, phase: .awaitingRestoreAck)
            }
            if run.phase == .awaitingRestoreReRead {
                log(entry?.value == run.probeValue ? "probe: RESTORE FAILED: set it back in the app" : "probe: previous value restored")
            }
            probeRun = nil
            nextControl()
        default:
            log("probe: unexpected reply ignored")
        }
    }
}
