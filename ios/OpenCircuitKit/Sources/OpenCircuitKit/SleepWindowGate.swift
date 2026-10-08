// The session's sleep-window read for the overnight-quiet drain gate — `RingSession.isInSleepWindow`'s
// decision, moved here unchanged so the ways it can read "awake" mid-sleep are unit-testable (#280).
// The rationale for each rule lives on `RingSession.isInSleepWindow` and its stored properties; this
// file only holds the arithmetic. `OvernightQuiet` is the clock floor the drain gate adds on top.

import Foundation

public enum SleepWindowGate {

    /// The learned (generous skin-temp) window ends at wake + `SleepWindow.habitualInterval`'s 1.5 h
    /// `wakeMargin`; the drain gate trims that back off to the learned wake ("earliest wake").
    public static let drainWakeMarginTrim: TimeInterval = 5400
    /// Fail-safe ceiling: overnight-quiet never holds longer than this past the earliest wake.
    public static let maxQuietPastLearnedWake: TimeInterval = 6 * 3600

    /// Whether `now` is inside the sleep window, as `RingSession` resolves it.
    ///
    /// - Parameters:
    ///   - nightWindow: the resolved window, or nil before `refreshNightWindowIfNeeded` has run.
    ///   - isExplicit: `nightWindow` is an explicit schedule (iOS Sleep / manual), trusted as-is.
    ///   - morningWakeConfirmedAt: the walking latch past the earliest wake (learned windows only).
    ///   - fallback: the stored bed/wake schedule's window, consulted only when `nightWindow` is nil.
    public static func isInSleepWindow(now: Date,
                                       nightWindow: DateInterval?,
                                       isExplicit: Bool,
                                       morningWakeConfirmedAt: Date?,
                                       fallback: () -> DateInterval?) -> Bool {
        if let w = nightWindow {
            if isExplicit { return w.contains(now) }
            let earliestWake = w.end.addingTimeInterval(-drainWakeMarginTrim)
            guard earliestWake > w.start else { return false }  // trimmed away → treat as awake
            if now < w.start { return false }                   // before tonight's bedtime
            let ceiling = earliestWake.addingTimeInterval(maxQuietPastLearnedWake)
            if now >= ceiling { return false }                  // fail-safe: force the one morning drain
            if now < earliestWake { return true }               // deep night, before any plausible wake
            // Past the learned wake: quiet until a walk is seen THIS night (a latch from before
            // `w.start` belongs to an earlier night and is ignored).
            if let confirmed = morningWakeConfirmedAt, confirmed >= w.start, confirmed <= now { return false }
            return true
        }
        guard let w = fallback() else { return false }
        return w.contains(now)
    }
}
