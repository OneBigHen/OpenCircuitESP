// Ring event log carried by `0x50` frames (docs/PROTOCOL.md §5.5.1) — and the ring's OWN
// activity sessions decoded from it.
//
// WHY THIS EXISTS. The ring decides for itself when the wearer is active: while it is, it stops
// its ~2.5-min unsolicited pushes (the link stays UP — no disconnect, no error), so a suspended
// app is never woken, observes no steps, and receives the whole bout later as back-filled `0x4c`
// history. The step-based activity gate (#144) then sees HR ≥ 100 with no concurrent steps and
// fires "elevated heart rate while inactive" on a walk (tester report 2026-09-27). The ring's own
// start/stop markers for those bouts ride in the `0x50` frame we already receive at the end of
// every drain — this file turns them into intervals the alert gate can honour, which is what the
// official app does ("… while in a non-exercising state", with a separate auto-sport reminder).
//
// Pure (no Apple frameworks) so it unit-tests on the CLI.

import Foundation

/// One 6-byte entry of a `0x50` frame: `[type][value][cursor:4 BE]`, cursor in `Command.syncEpoch`
/// seconds. 🟢 layout (every one of 314 distinct entries across 29 diagnostics bundles / 2 rings
/// divides the payload exactly, no trailer); the meaning of each (type, value) is tagged on
/// `RingEventLog.Kind`.
public struct RingEvent: Equatable, Hashable, Codable, Sendable {
    public let type: UInt8
    public let value: UInt8
    public let cursor: UInt32

    public init(type: UInt8, value: UInt8, cursor: UInt32) {
        self.type = type
        self.value = value
        self.cursor = cursor
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(Command.syncEpoch) + TimeInterval(cursor))
    }
}

public enum RingEventLog {
    public static let opcode: UInt8 = 0x50
    public static let entryLength = 6

    /// Activity-session markers (type `0x10`). 🟡 PROBABLE, from the 2026-09-27 AD/Gen2 bundle +
    /// that day's iPhone system log: `0f`→`0a` brackets a user-confirmed 10:40–11:15 walk
    /// (10:52:05 → 11:23:55), and the ring resumed its pushes 8 s after the `0a`; a 09-26 pair
    /// (18:01:40 → 18:22:20) ended its silent gap 1 s after the `0a`. On the AD ring (known
    /// timezone) all 7 `0f`/`0a` pairs are daytime while its `07`/`08` pairs sharing the type sit in
    /// its overnight window (e.g. 00:09 → 08:34) — so `07`/`08` are NOT treated as activity here
    /// (🔴 guess: sleep markers). Both corpus rings emit `0f`/`0a` (21 pairs in all).
    public static let activityType: UInt8 = 0x10
    public static let activityStart: UInt8 = 0x0f
    public static let activityEnd: UInt8 = 0x0a

    /// Longest an UNCLOSED session may run. A POLICY bound, not a measurement: the longest closed
    /// pair in the corpus is 68 min (21 pairs, 2 rings), so 4 h covers a long hike with margin
    /// while capping what a lost end marker can suppress.
    public static let openSessionCap: TimeInterval = 4 * 3600

    /// One decoded `0x50` event frame.
    public struct Frame: Equatable, Sendable {
        /// Entries the ring holds but did NOT show (`[2]`, 🟡). Non-zero means the log has
        /// overflowed the 40-entry frame: what is shown is the OLDEST 40, so every newer marker —
        /// including the activity session that just ended — is not on the wire at all.
        public let hiddenCount: Int
        public let events: [RingEvent]
    }

    /// Decode a `0x50` event frame, or nil when it is not one. NO XOR trailer (§5.5): after
    /// `50 00 <hidden>` the payload must be a whole number of 6-byte entries. Of the legacy shapes
    /// `EpochRecord.parseEndOfHistory` handles, the 8- and 12-byte ones are not whole entries and
    /// return nil here; the 9-byte `15 <sub> <cursor>` one IS a single entry and decodes as one
    /// (type `0x15`), which no consumer below reads.
    public static func decodeFrame(_ frame: [UInt8]) -> Frame? {
        guard frame.count >= 3 + entryLength, frame[0] == opcode, frame[1] == 0x00 else { return nil }
        let payload = frame[3...]
        guard payload.count % entryLength == 0 else { return nil }
        let events = stride(from: payload.startIndex, to: payload.endIndex, by: entryLength).map { (o: Int) -> RingEvent in
            // Split into typed parts: the one-expression form times out the Xcode 26.x type-checker.
            let b0: UInt32 = UInt32(frame[o + 2]) << 24
            let b1: UInt32 = UInt32(frame[o + 3]) << 16
            let b2: UInt32 = UInt32(frame[o + 4]) << 8
            let b3: UInt32 = UInt32(frame[o + 5])
            return RingEvent(type: frame[o], value: frame[o + 1], cursor: b0 | b1 | b2 | b3)
        }
        return Frame(hiddenCount: Int(frame[2]), events: events)
    }

    /// The entries of a `0x50` event frame (see `decodeFrame`).
    public static func decode(_ frame: [UInt8]) -> [RingEvent]? { decodeFrame(frame)?.events }

    /// The ring's activity sessions as `[start, end]` intervals, from `0x10` start/end markers of
    /// ONE ring (pair per ring — interleaving two rings' markers would pair A's start with B's end).
    ///
    /// EVERY session is capped at `openSessionCap`, closed or not — so a LOST end marker can
    /// silence the HR rules for a bounded time, never for the ledger's whole retention. A start
    /// followed by another start means the first one's end was lost: the first is closed at the
    /// second (still capped). A start with no later end is in progress and runs to `now` (capped).
    /// An end with no open start is DROPPED — its start cannot be bounded, and inventing one would
    /// suppress alerts on a guess. Duplicates (the ring re-sends its log) collapse. Only ever used
    /// to SUPPRESS, so an unpaired or unknown marker costs at most a missed suppression.
    public static func activitySessions(_ events: [RingEvent], now: Date) -> [(Date, Date)] {
        let markers = Set(events.filter { $0.type == activityType
                && ($0.value == activityStart || $0.value == activityEnd) })
            .sorted { $0.cursor < $1.cursor }
        var sessions: [(Date, Date)] = []
        func close(_ s: Date, at e: Date) {
            sessions.append((s, min(e, s.addingTimeInterval(openSessionCap))))
        }
        var open: Date?
        for m in markers {
            if m.value == activityStart {
                if let s = open { close(s, at: m.date) }
                open = m.date
            } else if let s = open {
                close(s, at: m.date)
                open = nil
            }
        }
        if let s = open, s <= now { close(s, at: now) }
        return sessions
    }
}

/// Persisted, de-duplicated activity markers across drains, per ring. One `0x50` shows at most 40
/// entries and the log is cleared from time to time (§5.5.1), so markers are banked as they are
/// seen. Codable so the app can keep it in UserDefaults — no SwiftData schema change.
public struct RingActivityEventLedger: Codable, Equatable, Sendable {
    /// Activity markers keyed by ring identifier.
    public private(set) var events: [String: [RingEvent]]
    /// The latest overflow state seen per ring: `hidden` > 0 means newer markers are not visible
    /// (§5.5.1) and the ring-activity gate is blind for that ring until the log clears.
    public private(set) var overflow: [String: Overflow]

    public struct Overflow: Codable, Equatable, Sendable {
        public let hidden: Int
        public let seenAt: Date
    }

    /// How long a marker is kept. The alert engine looks back 2 h
    /// (`LiveHealthAlerts.contextWindow`), so 48 h keeps every marker it can ask about with ample
    /// margin, and bounds the blob.
    public static let retention: TimeInterval = 48 * 3600

    public init(events: [String: [RingEvent]] = [:], overflow: [String: Overflow] = [:]) {
        self.events = events
        self.overflow = overflow
    }

    /// One ledger for the whole app; the gate asks "was the WEARER active", so sessions from every
    /// ring count, but each ring's markers are paired only with its own.
    public static let defaultsKey = "ring.activityEvents.v2"

    /// The stored ledger, or an empty one when absent or unreadable (an unreadable blob can only
    /// cost a missed suppression — the alert still fires — so it is not worth surfacing).
    public static func load(_ defaults: UserDefaults = .standard) -> RingActivityEventLedger {
        guard let data = defaults.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return ledger
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Bank one decoded frame from `ring`: its activity markers (dropping duplicates and anything
    /// older than `retention` or implausibly in the future — the log also carries type-`0x17`
    /// entries with cursors years off, filtered by type anyway) and its overflow state.
    public mutating func merge(_ frame: RingEventLog.Frame, ring: String, now: Date) {
        let keep = frame.events.filter { $0.type == RingEventLog.activityType
            && ($0.value == RingEventLog.activityStart || $0.value == RingEventLog.activityEnd) }
        let lo = now.addingTimeInterval(-Self.retention)
        let hi = now.addingTimeInterval(3600)
        events[ring] = Array(Set((events[ring] ?? []) + keep))
            .filter { $0.date >= lo && $0.date <= hi }
            .sorted { $0.cursor < $1.cursor }
        // Re-stamp only when the hidden count CHANGES: while overflowed the ring answers every
        // keepalive with the same frozen frame (~every 3 min), and re-stamping would re-save and
        // re-log "gate blind" on each one.
        if frame.hiddenCount == 0 {
            overflow[ring] = nil
        } else if overflow[ring]?.hidden != frame.hiddenCount {
            overflow[ring] = Overflow(hidden: frame.hiddenCount, seenAt: now)
        }
        // Other rings are only pruned here, so a retired ring's markers and "gate blind" flag
        // would otherwise live forever.
        for other in events.keys where other != ring {
            events[other] = events[other]?.filter { $0.date >= lo }
            if events[other]?.isEmpty == true { events[other] = nil }
        }
        for (other, o) in overflow where other != ring && o.seenAt < lo { overflow[other] = nil }
    }

    /// Every ring's activity sessions currently on record, each ring paired on its own.
    public func sessions(now: Date) -> [(Date, Date)] {
        events.keys.sorted().flatMap { RingEventLog.activitySessions(events[$0] ?? [], now: now) }
    }

    /// The same sessions as motion evidence for the active-energy gate
    /// (`ExerciseMinutes.MotionEvidence.activityIntervals`, #281). They are widened back by
    /// `HealthAlertEvaluator.ringActivityLead` exactly as the alert gate widens them: the ring stamps
    /// a session when it has recognised the activity, not when the activity began.
    public func corroboratingIntervals(now: Date) -> [DateInterval] {
        HealthAlertEvaluator.ringActivityIntervals(sessions(now: now)).compactMap { start, end in
            end >= start ? DateInterval(start: start, end: end) : nil
        }
    }
}
