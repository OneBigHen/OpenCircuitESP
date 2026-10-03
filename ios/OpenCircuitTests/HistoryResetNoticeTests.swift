import XCTest
@testable import OpenCircuit

/// #243 — the store-wipe notice from #40 never showed: `localHistoryWasReset` was set by
/// `wipeAndRecoverForeground` but nothing read or cleared it. These pin `HistoryResetNotice`, the
/// reader ContentView drives: a foreground launch shows it once and the dismissal clears it, an unset
/// flag shows nothing, and a background launch neither shows nor clears it.
///
/// Every test uses its own `UserDefaults` suite — NONE touch `.standard`, where a real flag may sit.
@MainActor
final class HistoryResetNoticeTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HistoryResetNoticeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The key is the one already on real phones (#40); renaming it would orphan every set flag.
    func testFlagKeyIsTheShippedKey() {
        XCTAssertEqual(OpenCircuitApp.historyResetDefaultsKey, "localHistoryWasReset")
        XCTAssertEqual(HistoryResetNotice.flagKey, OpenCircuitApp.historyResetDefaultsKey)
    }

    /// Flag set → the foreground launch gets the notice, dismissing it clears the flag and its date,
    /// and the next foreground launch gets nothing.
    func testFlagSetShowsOnceThenClears() {
        let wipedAt = Date(timeIntervalSince1970: 1_790_000_000)
        HistoryResetNotice.record(at: wipedAt, in: defaults)

        let notice = HistoryResetNotice.pending(isBackground: false, defaults: defaults)
        XCTAssertEqual(notice, HistoryResetNotice(resetAt: wipedAt),
                       "a foreground launch with the flag set shows the notice, with the wipe's date")
        XCTAssertTrue(defaults.bool(forKey: HistoryResetNotice.flagKey),
                      "reading the notice is not acknowledging it — only the dismissal clears")

        HistoryResetNotice.acknowledge(defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: HistoryResetNotice.flagKey))
        XCTAssertNil(defaults.object(forKey: HistoryResetNotice.dateKey))
        XCTAssertNil(HistoryResetNotice.pending(isBackground: false, defaults: defaults),
                     "once dismissed, the notice never shows again")
    }

    /// Flag unset → no notice, even when a stray date is present.
    func testFlagUnsetShowsNothing() {
        XCTAssertNil(HistoryResetNotice.pending(isBackground: false, defaults: defaults))
        defaults.set(Date(), forKey: HistoryResetNotice.dateKey)
        XCTAssertNil(HistoryResetNotice.pending(isBackground: false, defaults: defaults),
                     "a date without the flag is not a wipe")
    }

    /// A background launch neither shows the notice nor clears it, so the next foreground launch
    /// still can.
    func testBackgroundLaunchNeitherShowsNorClears() {
        let wipedAt = Date(timeIntervalSince1970: 1_790_000_000)
        HistoryResetNotice.record(at: wipedAt, in: defaults)

        XCTAssertNil(HistoryResetNotice.pending(isBackground: true, defaults: defaults),
                     "a background launch must never show the notice")
        XCTAssertTrue(defaults.bool(forKey: HistoryResetNotice.flagKey),
                      "a background launch must never clear the flag")
        XCTAssertEqual(defaults.object(forKey: HistoryResetNotice.dateKey) as? Date, wipedAt)

        XCTAssertEqual(HistoryResetNotice.pending(isBackground: false, defaults: defaults),
                       HistoryResetNotice(resetAt: wipedAt),
                       "the next foreground launch still shows it")
    }

    /// A flag left by a wipe before #243 has no date: the notice still shows, and does not claim the
    /// wipe just happened.
    func testUndatedFlagShowsWithoutClaimingItJustHappened() {
        defaults.set(true, forKey: HistoryResetNotice.flagKey)   // what builds before #243 wrote

        let notice = HistoryResetNotice.pending(isBackground: false, defaults: defaults)
        XCTAssertEqual(notice, HistoryResetNotice(resetAt: nil))

        let text = notice?.message(dateText: { _ in "DATE" }) ?? ""
        XCTAssertTrue(text.contains("not recorded"), text)
        XCTAssertFalse(text.contains("DATE"), text)
        for word in ["just", "today", "recently"] {
            XCTAssertFalse(text.lowercased().contains(word), "an undated notice must not say '\(word)': \(text)")
        }
    }

    /// A dated notice says when the wipe ran, and both forms point at Apple Health.
    func testDatedMessageNamesTheDate() {
        let text = HistoryResetNotice(resetAt: Date(timeIntervalSince1970: 0))
            .message(dateText: { _ in "3 Oct 2026 at 09:41" })
        XCTAssertTrue(text.hasPrefix("On 3 Oct 2026 at 09:41, "), text)
        XCTAssertTrue(text.contains("Apple Health"), text)
        XCTAssertTrue(HistoryResetNotice(resetAt: nil).message().contains("Apple Health"))
    }
}
