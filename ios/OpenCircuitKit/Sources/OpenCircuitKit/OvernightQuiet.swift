// Wall-clock floor under the overnight-quiet drain gate (#280, decision 60).
//
// WHY. An automatic history drain opens `02 .. cursor≈now ..`, which advances the ring's ONE resume
// pointer (PROTOCOL.md §3). OpenCircuit stores no cursor of its own, so an open that lands mid-sleep
// skips the still-unwritten part of the night for good. `HistoryDrainCadence.shouldDrain` already
// holds automatic drains inside the sleep window, but the window it is fed (`SleepWindowGate`) is
// built from state that can read "awake" while the wearer is asleep:
//   - a fresh background session drains before `refreshNightWindowIfNeeded` has run, so the window
//     is nil and the stored bed/wake schedule (22:30→06:30 unless the user set one) gates instead;
//   - the learned window comes from the RECORDED onset/wake, so one mis-staged night (a sync hole
//     read as a 03:30 wake) pulls the learned wake, and the +6 h ceiling with it, hours early;
//   - Sleep Focus ending drained as if it were a manual sync, bypassing the gate entirely.
// Tester night 2026-10-06→07 (issue #280): opens ran through the night and again from 06:21, and
// ~4 h of a real sleep were skipped on the wire.
//
// This floor is clock-only — no ring state, nothing learned — so none of those can open it:
//   - 21:00–07:00 local: always quiet.
//   - 07:00–11:00: quiet until a real walking bout is seen at or after 07:00 today (the lie-in).
//   - from 11:00: no opinion; the session's own window decides, as before.
// It only ever ADDS quiet (the drain gate ORs it with the session window), so it can delay a drain,
// never start one. A user-initiated sync never consults it.

import Foundation

public enum OvernightQuiet {

    /// Automatic drains are always held from this local hour…
    public static let hardQuietStartHour = 21
    /// …until this one, when the lie-in window starts.
    public static let lieInStartHour = 7
    /// The lie-in window ends here; past it the floor has no opinion.
    public static let lieInEndHour = 11

    /// Whether an AUTOMATIC history-drain open must be held right now.
    ///
    /// - Parameters:
    ///   - now: the instant being gated.
    ///   - morningWalkAt: when a real walking bout was last seen (see `RingSession`'s step handler).
    ///     Only a walk at or after 07:00 TODAY, and not after `now`, releases the lie-in window, so a
    ///     stale value from an earlier day, or a night-time bathroom walk, never does.
    ///   - calendar: resolves local time of day (injected so tests are deterministic).
    public static func suppressAutomaticHistoryOpen(now: Date,
                                                    morningWalkAt: Date?,
                                                    calendar: Calendar = .current) -> Bool {
        let minutes = minutesOfDay(now, calendar: calendar)
        if minutes >= hardQuietStartHour * 60 || minutes < lieInStartHour * 60 { return true }
        guard minutes < lieInEndHour * 60 else { return false }
        return !hasMorningWalk(morningWalkAt, now: now, calendar: calendar)
    }

    /// True between 07:00 and 11:00 local: the only span where a walk changes the answer, and so the
    /// only span in which the caller should record one.
    public static func isLieIn(_ now: Date, calendar: Calendar = .current) -> Bool {
        let minutes = minutesOfDay(now, calendar: calendar)
        return minutes >= lieInStartHour * 60 && minutes < lieInEndHour * 60
    }

    /// Whether `walkAt` counts as this morning's walk as seen from `now`: at or after 07:00 on `now`'s
    /// day and not in the future.
    public static func hasMorningWalk(_ walkAt: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let walkAt else { return false }
        return walkAt >= lieInStart(on: now, calendar: calendar) && walkAt <= now
    }

    /// 07:00 local on `now`'s day.
    static func lieInStart(on now: Date, calendar: Calendar) -> Date {
        // No 07:00 on `now`'s day only if a time-zone change skipped it; `now` then admits no walk
        // but one stamped at this very instant, which keeps the window quiet (the safe side).
        calendar.date(bySettingHour: lieInStartHour, minute: 0, second: 0, of: now) ?? now
    }

    static func minutesOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
