// HelioVerify's command line: the options, the help text and the parser. Kept out of main.swift so
// the parser is testable (main.swift's top-level code starts Bluetooth).

import Foundation
import ZeppKit

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
    var trace = false
    // Device controls (Controls.swift).
    var findSeconds: Double?
    var vibrate = false
    var listAlarms = false
    var setAlarm: (hour: UInt8, minute: UInt8, days: ZeppAlarmDays)?
    var deleteAlarmSlot: UInt8?
    var allowWrite = false
    var alerts = false

    var writesAlarms: Bool { setAlarm != nil || deleteAlarmSlot != nil }
    /// Any control flag: the run does the controls instead of live HR and the history fetch.
    var hasControls: Bool { findSeconds != nil || vibrate || listAlarms || writesAlarms || alerts }
}

let usage = """
HelioVerify — check an Amazfit Helio Strap / Ring over Bluetooth LE (macOS).

USAGE
  swift run HelioVerify [options]

Without a key: scans, connects, reads the standard battery level (if the strap exposes 0x2A19)
and firmware/hardware revision, and listens to standard heart-rate notifications (0x2A37; needs
Zepp's "Heart Rate Push" switch on).

With --key-file: also authenticates, prints the services list, reads the hardware and firmware
versions from the device-info endpoint (0x0043; never the serial number), reads battery over the
battery endpoint, reads the HEALTH settings (warns about switches that stop recording), streams
live HR, and runs a NON-DESTRUCTIVE history fetch (ack 03 09: the strap keeps everything),
printing summaries.

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
  --trace             Print every history-fetch control message both ways as hex, and each data
                      packet's length and counter byte (never its payload).
  --out <path>        Append each fetched round (raw hex + metadata, JSON lines) to this file and
                      fsync it. The file holds REAL HEALTH DATA: keep it out of git.
  --allow-delete      DESTRUCTIVE. Ack 03 01 ("saved, drop it from the strap") for each round
                      whose CRC matched, but only after it is durably written to --out. A round
                      without a CRC is kept (03 09). Requires --key-file and --out.
  --help              Show this help.

DEVICE CONTROLS (Helio Strap only; all need --key-file)
  Any of these runs the controls INSTEAD of live HR and the history fetch. After auth the strap's
  services list is printed with each endpoint's encryption, then which controls it supports. A
  control the strap does not list is reported as unsupported and nothing is sent for it.
  --find [n]          Find my strap: start "find device", stop it after n seconds (default 10,
                      max 60). A stop is also sent on Ctrl-C, on timeout and before exiting.
  --vibrate           One short buzz: find-device start, then stop 500 ms later. There is no
                      dedicated vibrate opcode (ZEPP_PROTOCOL.md §13.2).
  --alerts            Read-only: the config capabilities and the strap's haptic alert settings
                      (high/low HR, low SpO2, relax reminder), with the values it allows.
  --alarms            Read-only: list the alarms on the strap.
  --set-alarm HH:MM[,days]
                      WRITES STRAP STATE; needs --allow-write. Adds one enabled alarm in the lowest
                      free slot (never overwrites or deletes another), printing the list before and
                      after. days: once (default), daily, weekdays, weekend, or mon..sun joined by
                      ',' or '+', e.g. 07:30,mon,wed,fri. Sets the strap's clock first: alarms fire
                      in strap-local time.
  --delete-alarm <n>  WRITES STRAP STATE; needs --allow-write. Deletes the alarm in slot n (0-9),
                      e.g. the one --set-alarm made. Prints the list before and after.
  --allow-write       Permits --set-alarm / --delete-alarm. Without it nothing is written.

EXIT CODES
  0 ok · 1 usage · 2 Bluetooth unavailable · 3 timeout · 4 auth failed · 5 no device found
  130 interrupted (Ctrl-C)
"""

/// Why the command line was not accepted; main.swift prints it and exits.
enum OptionsError: Error, Equatable {
    /// `--help`: print `usage` and exit 0.
    case help
    /// A usage error: print the message and exit 1.
    case invalid(String)
}

/// Parses HelioVerify's arguments (without the program name). Pure: no I/O, no exit, so the write
/// gating below is unit-tested (HelioVerifyTests).
func parseOptions(_ args: [String]) throws -> Options {
    func fail(_ message: String) -> OptionsError { .invalid(message) }
    var o = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw fail("\(flag) needs a value") }
        return args[i]
    }
    func number(_ flag: String) throws -> Double {
        guard let n = Double(try value(flag)), n >= 0 else { throw fail("\(flag) needs a non-negative number") }
        return n
    }
    while i < args.count {
        switch args[i] {
        case "--help", "-h":
            throw OptionsError.help
        case "--key-file": o.keyFile = try value("--key-file")
        case "--allow-delete": o.allowDelete = true
        case "--out": o.outPath = try value("--out")
        case "--name": o.name = try value("--name")
        case "--scan-seconds": o.scanSeconds = try number("--scan-seconds")
        case "--hr-seconds": o.hrSeconds = Int(try number("--hr-seconds"))
        case "--since-hours": o.sinceHours = try number("--since-hours")
        case "--timeout": o.timeoutSeconds = try number("--timeout")
        case "--set-time": o.setTime = true
        case "--trace": o.trace = true
        case "--find":
            // Optional value: `--find` alone buzzes for 10 s.
            if i + 1 < args.count, let n = Double(args[i + 1]) {
                i += 1
                guard n > 0, n <= ZeppFindDevice.Configuration.maxFindDuration else { throw fail("--find takes a number of seconds above 0 and at most 60") }
                o.findSeconds = n
            } else {
                o.findSeconds = 10
            }
        case "--vibrate": o.vibrate = true
        case "--alarms": o.listAlarms = true
        case "--alerts": o.alerts = true
        case "--allow-write": o.allowWrite = true
        case "--set-alarm":
            guard let alarm = parseAlarmSpec(try value("--set-alarm")) else {
                throw fail("--set-alarm takes HH:MM[,days], e.g. 06:30 or 07:30,weekdays or 08:00,mon+wed")
            }
            o.setAlarm = alarm
        case "--delete-alarm":
            guard let slot = UInt8(try value("--delete-alarm")), slot < ZeppAlarm.slotCount else {
                throw fail("--delete-alarm takes a slot number 0-9")
            }
            o.deleteAlarmSlot = slot
        case "--types":
            let list = try value("--types").split(separator: ",")
            o.types = try list.map { code in
                let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
                let digits = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
                guard let raw = UInt8(digits, radix: 16), let type = ZeppFetchType(rawValue: raw) else {
                    throw fail("unknown fetch type '\(code)'")
                }
                return type
            }
        default:
            throw fail("unknown option '\(args[i])' (see --help)")
        }
        i += 1
    }
    if o.allowDelete && (o.keyFile == nil || o.outPath == nil) {
        throw fail("--allow-delete requires --key-file and --out: data is only dropped from the strap after it is durably saved")
    }
    if o.hasControls && o.keyFile == nil {
        throw fail("--find, --vibrate, --alerts and the alarm flags need --key-file: the strap only takes them after auth")
    }
    if o.writesAlarms && !o.allowWrite {
        throw fail("--set-alarm and --delete-alarm write the strap's alarms: add --allow-write to confirm")
    }
    if o.allowWrite && !o.writesAlarms {
        throw fail("--allow-write only applies to --set-alarm / --delete-alarm")
    }
    if o.setAlarm != nil && o.deleteAlarmSlot != nil {
        throw fail("one alarm write per run: use --set-alarm or --delete-alarm, not both")
    }
    // Alarm edits need the strap's clock set on this connection (ZEPP_PROTOCOL.md §14).
    if o.writesAlarms { o.setTime = true }
    return o
}

/// `HH:MM` or `HH:MM,days` (days per `ZeppAlarmDays(list:)`; omitted = once).
func parseAlarmSpec(_ text: String) -> (hour: UInt8, minute: UInt8, days: ZeppAlarmDays)? {
    let parts = text.split(separator: ",", maxSplits: 1).map(String.init)
    guard let time = parts.first else { return nil }
    let hm = time.split(separator: ":", omittingEmptySubsequences: false)
    guard hm.count == 2, (1...2).contains(hm[0].count), hm[1].count == 2,
          hm.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let hour = UInt8(hm[0]), let minute = UInt8(hm[1]), hour < 24, minute < 60 else { return nil }
    var days = ZeppAlarmDays.once
    if parts.count == 2 {
        guard let parsed = ZeppAlarmDays(list: parts[1]) else { return nil }
        days = parsed
    }
    return (hour, minute, days)
}
