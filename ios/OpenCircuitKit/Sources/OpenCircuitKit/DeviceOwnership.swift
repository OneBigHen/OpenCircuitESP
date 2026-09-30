// Which device owns which stretch of time (decision 28 of the Helio decisions of record, #215).
//
// A person may wear a RingConn ring and an Amazfit Helio Strap and switch between them. Both record
// the same sleep and the same steps, and Apple Health can't dedupe two devices writing under one
// app. So every switch is recorded as `(family, since)` in an append-only log, and:
//   • the owner of a moment is the family of the latest entry with `since <= t`;
//   • the RING owns all time before the first entry, so for a ring-only user (empty log) every rule
//     built on this is a no-op;
//   • a device only ingests, stores and writes to Apple Health what it recorded for time it owns.
//
// Pure value type: persisted by the app (UserDefaults), tested here.

import Foundation

public struct DeviceOwnershipLog: Codable, Equatable, Sendable {

    /// The device families that can own time. A timeline maps onto one (`init(timeline:)`).
    public enum Family: String, Codable, Sendable, CaseIterable {
        case ringConn
        case zeppOS

        /// `ringconn` is the ring; every other timeline (`zeppos:<id>`) is a Zepp OS device.
        public init(timeline: SyncDeviceID) {
            self = timeline == .ringConn ? .ringConn : .zeppOS
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let family: Family
        public let since: Date

        public init(family: Family, since: Date) {
            self.family = family
            self.since = since
        }
    }

    /// Oldest first; `since` never decreases.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = []
        for entry in entries { record(entry.family, since: entry.since) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Record a switch to `family` from `since`. No-op (returns false) when `family` already owns the
    /// present: the ring before any entry, or the last entry's family. Monotonic: a `since` earlier
    /// than the last entry's (the clock moved back) is clamped to the last entry's.
    @discardableResult
    public mutating func record(_ family: Family, since: Date) -> Bool {
        guard family != currentFamily else { return false }
        let clamped = entries.last.map { max($0.since, since) } ?? since
        entries.append(Entry(family: family, since: clamped))
        return true
    }

    /// Who owns the present: the last entry's family, or the ring when there is none.
    public var currentFamily: Family { entries.last?.family ?? .ringConn }

    /// Who owns `t`: the family of the latest entry with `since <= t`; the ring before the first.
    public func owner(at t: Date) -> Family {
        entries.last(where: { $0.since <= t })?.family ?? .ringConn
    }

    /// Whether `timeline`'s device owns `t`.
    public func owns(_ timeline: SyncDeviceID, at t: Date) -> Bool {
        owner(at: t) == Family(timeline: timeline)
    }

    /// A night belongs to the owner at the midpoint of its in-bed window.
    public func owner(ofNightFrom inBedStart: Date, to inBedEnd: Date) -> Family {
        owner(at: Self.midpoint(inBedStart, inBedEnd))
    }

    public static func midpoint(_ start: Date, _ end: Date) -> Date {
        end > start ? start.addingTimeInterval(end.timeIntervalSince(start) / 2) : start
    }

    /// The start of `family`'s CURRENT ownership, or nil when it doesn't own the present. The ring
    /// with an empty log has owned all time: `.distantPast`.
    public func currentStart(of family: Family) -> Date? {
        guard currentFamily == family else { return nil }
        return entries.last?.since ?? .distantPast
    }

    /// Every half-open `[start, end)` interval `family` owns, oldest first. The last is open-ended
    /// (`.distantFuture`) when `family` owns the present.
    public func intervals(of family: Family) -> [(start: Date, end: Date)] {
        var out: [(start: Date, end: Date)] = []
        var boundaries: [(family: Family, since: Date)] = [(.ringConn, .distantPast)]
        boundaries += entries.map { ($0.family, $0.since) }
        for (index, boundary) in boundaries.enumerated() where boundary.family == family {
            let end = index + 1 < boundaries.count ? boundaries[index + 1].since : .distantFuture
            if end > boundary.since { out.append((boundary.since, end)) }
        }
        return out
    }
}
