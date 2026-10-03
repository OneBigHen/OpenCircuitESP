import Foundation

/// The one-time "local history was reset" notice (#243). #40 raised `historyResetDefaultsKey` after
/// the last-resort store wipe "so the UI can tell the user", but nothing ever read or cleared it: a
/// real device carried the flag across builds 59–61 and its user was never told. This is the reader.
///
/// Pure over an injected `UserDefaults`, so the three rules are unit-testable without a launch:
///   * the wipe RECORDS the flag and its date (`record`);
///   * only a FOREGROUND launch may see the notice (`pending`) — a background launch neither shows
///     it nor clears it, so the next foreground launch still can;
///   * the flag is cleared only once the user has dismissed the notice (`acknowledge`), so a launch
///     that never got to present it does not lose it.
///
/// A flag left by a wipe before #243 has no date. Its notice must not say the reset just happened:
/// it may be weeks old (the device above is one), so it says the date was not recorded instead.
struct HistoryResetNotice: Equatable {
    /// When the wipe ran; nil for a flag left by a wipe that recorded no date (pre-#243).
    let resetAt: Date?

    /// The #40 flag. `OpenCircuitApp.historyResetDefaultsKey` names this same key; the value is the
    /// one already on real phones, so it must not change.
    static let flagKey = "localHistoryWasReset"
    /// When the wipe ran (#243). Absent on a flag raised before #243.
    static let dateKey = "localHistoryResetAt"

    static let title = "Local history was reset"

    /// Raise the flag and stamp its date. Called only by `wipeAndRecoverForeground`. The date is
    /// written first, so a reader never sees a fresh flag paired with no date.
    static func record(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: dateKey)
        defaults.set(true, forKey: flagKey)
    }

    /// The notice to show, or nil. Never on a background launch (`isBackground == true`), and it
    /// touches nothing: reading is not acknowledging.
    static func pending(isBackground: Bool, defaults: UserDefaults = .standard) -> HistoryResetNotice? {
        guard !isBackground, defaults.bool(forKey: flagKey) else { return nil }
        return HistoryResetNotice(
            resetAt: defaults.object(forKey: dateKey) as? Date)
    }

    /// The user has seen the notice: clear the flag and its date, so it never shows again and the
    /// flag is once more a signal that a wipe ran (Gate B reads it from a pulled copy of the app's
    /// data, and before #243 found it set on every run).
    static func acknowledge(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: flagKey)
        defaults.removeObject(forKey: dateKey)
    }

    /// The notice body. Plain language, and honest about what is known: nothing records whether the
    /// rollup backup succeeded, so it says what a reset is designed to keep rather than claiming it
    /// did. `dateText` is a seam for tests; the default is the user's locale.
    func message(dateText: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> String {
        let when: String
        if let resetAt {
            when = "On \(dateText(resetAt)), OpenCircuit"
        } else {
            when = "At some point before this version (the date was not recorded), OpenCircuit"
        }
        return when + " could not open the data it keeps on this phone and had to rebuild it. "
            + "A rebuild is meant to keep your sleep summaries, daily step totals and logged "
            + "entries, but the detailed readings stored only on this phone were removed. "
            + "Anything already saved to Apple Health is still there."
    }
}
