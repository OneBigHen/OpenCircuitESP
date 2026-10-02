// Which device owns which stretch of time (decision 28 of the Helio decisions of record, #215).
//
// A person may wear a RingConn ring and an Amazfit Helio Strap and switch between them. Both record
// the same sleep and the same steps, and Apple Health can't dedupe two devices writing under one
// app. So every switch is recorded as `(family, since)` in an append-only log, and:
//   • the owner of a moment is the family of the latest entry with `since <= t`;
//   • the RING owns all time before the first entry, so for a ring-only user (empty log) every rule
//     built on this is a no-op;
//   • a device only ingests, stores and writes to Apple Health what it recorded for time it owns;
//   • a night belongs to the device you went to bed with (28a, `owner(ofNightFrom:to:)`).
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

    /// The start of the ownership stretch that contains `t`: the latest entry's `since` at or before
    /// `t`, or `.distantPast` before the first entry. Decision 28b clamps a step row to it, so the row
    /// lies wholly in its device's time (with an empty log: `.distantPast`, no clamp).
    public func ownershipStart(at t: Date) -> Date {
        entries.last(where: { $0.since <= t })?.since ?? .distantPast
    }

    /// Decision 28a (review-224b S-C): the device you went to bed with keeps the night. A window with
    /// a switch inside belongs to the owner just before the first switch; one without belongs to its
    /// single owner. Both are the owner at the in-bed START. A switch at exactly the in-bed start goes
    /// to the NEW device: it counts as made before bed (`owner(at:)`'s `since <= t`), the opposite of a
    /// literal "owner just before the switch". One instant both devices' windows can share
    /// would still disagree between two different windows, so the store also never lets one device's
    /// night replace the other's (`LocalStore.nightKeeping`).
    public func owner(ofNightFrom inBedStart: Date, to inBedEnd: Date) -> Family {
        owner(at: inBedStart)
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

    // MARK: Decision 29: baselines are per device

    /// `items` measured by `family`: those whose time (`time`) it owned. With an empty log every item
    /// is the ring's, so this returns `items` unchanged.
    public func only<T>(_ family: Family, _ items: [T], time: (T) -> Date) -> [T] {
        guard !isEmpty else { return items }
        return items.filter { owner(at: time($0)) == family }
    }

    /// `items` from the same device as the NEWEST one (by `time`): the history a "your usual" for that
    /// item may use (decision 29). With an empty log, `items` unchanged.
    public func sameDeviceAsNewest<T>(_ items: [T], time: (T) -> Date) -> [T] {
        guard !isEmpty, let newest = items.max(by: { time($0) < time($1) }) else { return items }
        return only(owner(at: time(newest)), items, time: time)
    }

    /// Whether a sample `recordedBy` the device on `timeline` at `start` was measured by `family`
    /// during `family`'s own time (a device's catch-up of the other's time is neither's baseline).
    /// Always true for the ring on an empty log.
    public func isOwn(recordedBy timeline: SyncDeviceID, at start: Date, by family: Family) -> Bool {
        Family(timeline: timeline) == family && owner(at: start) == family
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
