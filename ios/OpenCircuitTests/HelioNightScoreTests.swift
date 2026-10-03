import SwiftData
import XCTest
import OpenCircuitKit
import ZeppKit
@testable import OpenCircuit

// #246 / decision 48: the Helio Strap's nights are scored on the phone, like the ring's, so
// Readiness works with the strap. Every reading, id and time here is synthetic.
//
// The strap's HRV is taken as RMSSD on Amazfit's product-line documentation and that statistic is
// still 🟡 (decision 44): no capture has compared the `0x49` byte with the vendor app's number. So
// the `stressScore` these tests assert is "overnight recovery computed from a value we believe is
// RMSSD", not a confirmed one.

@MainActor
final class HelioNightScoreTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let ownership = OwnershipOverride()
    private let strapID = "5B1E4C2A-0000-4000-8000-000000000246"
    private let calendar = Calendar.current

    private var strap: SyncDeviceID { SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: strapID) }
    /// A second strap, to prove the family rule rather than one hard-coded timeline.
    private var otherStrap: SyncDeviceID {
        SyncDeviceID.timeline(for: .zeppOS(model: ""), identityID: "5B1E4C2A-0000-4000-8000-000000000247")
    }

    override func setUp() {
        super.setUp()
        ownership.install(.strapOwnsAllTime)   // a strap-only install (decision 28's first entry)
    }

    override func tearDown() {
        ownership.restore()
        containers.removeAll()
        super.tearDown()
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self, StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    // MARK: Fixtures

    /// Local midnight `daysAgo` days before today (the real clock, so "ended today" is real).
    private func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: Date()))!
    }

    /// A strap night that woke an hour ago and went to bed eight hours before that, so it both
    /// "ended today" for the Readiness card and lies wholly in the past for `ingest`'s future guard.
    private func lastNightWindow() -> DateInterval {
        let end = Date().addingTimeInterval(-3600)
        return DateInterval(start: end.addingTimeInterval(-8 * 3600), end: end)
    }

    /// A window of the night `daysAgo` days ago: in bed 23:00 the evening before, up at 07:00.
    private func window(daysAgo: Int) -> DateInterval {
        DateInterval(start: day(daysAgo).addingTimeInterval(-3600), end: day(daysAgo).addingTimeInterval(7 * 3600))
    }

    /// Strap-shaped staging over `w`: no `.inBed` segment (the strap's record has none), light →
    /// deep → a short wake → REM → light, filling the window.
    private func segments(_ w: DateInterval) -> [SleepSegment] {
        let d = w.duration
        func at(_ fraction: Double) -> Date { w.start.addingTimeInterval(d * fraction) }
        return [
            SleepSegment(start: w.start, end: at(0.35), stage: .asleepCore),
            SleepSegment(start: at(0.35), end: at(0.5), stage: .asleepDeep),
            SleepSegment(start: at(0.5), end: at(0.55), stage: .awake),
            SleepSegment(start: at(0.55), end: at(0.75), stage: .asleepREM),
            SleepSegment(start: at(0.75), end: w.end, stage: .asleepCore),
        ]
    }

    private func night(_ w: DateInterval) -> HelioSleepSelection.Night {
        HelioSleepSelection.Night(segments: segments(w), window: w, strapScore: 77,
                                  recordedTimeZone: TimeZone(identifier: "UTC"))
    }

    /// One heart-rate reading every five minutes across `w`.
    private func heartRate(_ w: DateInterval, bpm: Double = 56) -> [QuantitySample] {
        stride(from: w.start.timeIntervalSince1970, to: w.end.timeIntervalSince1970, by: 300).map {
            QuantitySample(kind: .heartRate, start: Date(timeIntervalSince1970: $0), value: bpm)
        }
    }

    /// Three HRV readings in `w`, stored as `.hrvSDNN` (the app's only HRV kind) holding RMSSD (🟡).
    private func hrv(_ w: DateInterval, ms: [Double] = [41, 47, 44]) -> [QuantitySample] {
        ms.enumerated().map {
            QuantitySample(kind: .hrvSDNN,
                           start: w.start.addingTimeInterval(w.duration * (0.3 + 0.15 * Double($0.offset))),
                           value: $0.element)
        }
    }

    /// Temperature minutes across `w` at `celsius`, dense enough to pass the nightly coverage gate.
    private func temperatures(_ w: DateInterval, celsius: Double) -> [QuantitySample] {
        stride(from: w.start.timeIntervalSince1970, to: w.end.timeIntervalSince1970, by: 300).map {
            QuantitySample(kind: .temperature, start: Date(timeIntervalSince1970: $0), value: celsius)
        }
    }

    /// A ring night with a stored skin temperature, the way `RingSession` stores one.
    @discardableResult
    private func saveRingNight(_ store: LocalStore, daysAgo: Int, skinTempC: Double,
                               sleepScore: Int = 0) throws -> StoredSleepSummary? {
        let w = window(daysAgo: daysAgo)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments(w)
        extras.skinTempC = skinTempC
        extras.sleepScore = sleepScore
        _ = try store.saveSleepSummary(SleepStaging.summary(segments(w)),
                                       night: SleepNightKey.night(inBedStart: w.start, inBedEnd: w.end),
                                       inBedStart: w.start, inBedEnd: w.end,
                                       sleepOnset: w.start, sleepWake: w.end, extras: extras)
        return try store.sleepSummaryOverlapping(start: w.start, end: w.end)
    }

    private func row(_ store: LocalStore, _ w: DateInterval) throws -> StoredSleepSummary {
        try XCTUnwrap(try store.sleepSummaryOverlapping(start: w.start, end: w.end))
    }

    // MARK: The sync order: the HRV round lands after the sleep round

    /// `HelioFetchPlan.types` fetches sleep sessions BEFORE HRV and temperature, so the first
    /// `saveHelioNight` of a sync has neither. `finishSync` re-saves each stored night, and that
    /// re-save is what carries the sync's HRV and temperatures onto it.
    func testTheHRVRoundArrivingAfterTheSleepRoundStillEndsWithBothScores() throws {
        let plan = HelioFetchPlan.types
        let sleepAt = try XCTUnwrap(plan.firstIndex(of: .sleepSession))
        XCTAssertLessThan(sleepAt, try XCTUnwrap(plan.firstIndex(of: .hrv)),
                          "this test only means something while sleep is fetched before HRV")
        XCTAssertLessThan(sleepAt, try XCTUnwrap(plan.firstIndex(of: .temperature)))

        let store = try makeStore()
        let w = window(daysAgo: 1)
        // The activity round (heart rate) comes first in the plan.
        _ = try store.ingest(heartRate(w), device: strap)

        // Round: sleep sessions. No HRV and no temperature stored yet.
        XCTAssertEqual(try store.saveHelioNight(night(w), device: strap), .inserted)
        let afterSleepRound = try row(store, w)
        XCTAssertGreaterThan(afterSleepRound.sleepScore, 0, "it scores on what it has")
        XCTAssertEqual(afterSleepRound.stressScore, 0, "no HRV has arrived yet")

        // Rounds: temperature, then HRV.
        _ = try store.ingest(temperatures(w, celsius: 34.1), device: strap)
        _ = try store.ingest(hrv(w), device: strap)

        // `finishSync`'s re-save of every stored night.
        XCTAssertEqual(try store.saveHelioNight(night(w), device: strap), .updated)
        let final = try row(store, w)
        XCTAssertGreaterThan(final.sleepScore, 0)
        XCTAssertEqual(final.stressScore, SleepStress.overnightScore(rmssd: [41, 44, 47]),
                       "overnight recovery from the sync's HRV (🟡 RMSSD, decision 44)")
        XCTAssertGreaterThan(final.skinTempC, 0, "the temperature landed too")
    }

    /// A later sync that keeps the stored night (`.keptFullerStoredNight` returns before
    /// `applyExtras` ever runs) leaves the score where it is.
    func testAReSyncThatKeepsTheStoredNightLeavesItScored() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: strap)
        _ = try store.ingest(hrv(w), device: strap)
        XCTAssertEqual(try store.saveHelioNight(night(w), device: strap), .inserted)
        let scored = try row(store, w)
        let sleepScore = scored.sleepScore, stressScore = scored.stressScore
        XCTAssertGreaterThan(sleepScore, 0)
        XCTAssertGreaterThan(stressScore, 0)

        // A thinner re-staging of the same night: only the first half arrives.
        let thin = DateInterval(start: w.start, end: w.start.addingTimeInterval(w.duration / 2))
        XCTAssertEqual(try store.saveHelioNight(night(thin), device: strap), .keptFullerStoredNight)
        let after = try row(store, w)
        XCTAssertEqual(after.sleepScore, sleepScore)
        XCTAssertEqual(after.stressScore, stressScore)
    }

    // MARK: The repair pass

    /// A night stored by builds 59–62: hypnogram and temperature, no scores. The pass gives it both,
    /// and running it again changes nothing at all (not even `updatedAt`).
    func testThePassScoresAnUnscoredStrapNightOnceAndASecondRunChangesNothing() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: strap)
        _ = try store.ingest(hrv(w), device: strap)
        try storeUnscored(store, w)
        XCTAssertEqual(try row(store, w).sleepScore, 0)

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [try row(store, w).night])
        let scored = try row(store, w)
        XCTAssertGreaterThan(scored.sleepScore, 0)
        XCTAssertEqual(scored.stressScore, SleepStress.overnightScore(rmssd: [41, 44, 47]))
        let before = fingerprint(scored)

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [], "idempotent")
        XCTAssertEqual(fingerprint(try row(store, w)), before, "nothing moved, including updatedAt")
    }

    /// The pass computes the SAME number the save path would have, so a repaired night and a
    /// freshly stored one are indistinguishable.
    func testThePassAgreesWithTheSavePath() throws {
        let w = window(daysAgo: 1)

        let saved = try makeStore()
        _ = try saved.ingest(heartRate(w), device: strap)
        _ = try saved.ingest(hrv(w), device: strap)
        _ = try saved.saveHelioNight(night(w), device: strap)

        let repaired = try makeStore()
        _ = try repaired.ingest(heartRate(w), device: strap)
        _ = try repaired.ingest(hrv(w), device: strap)
        try storeUnscored(repaired, w)
        _ = try repaired.scoreUnscoredHelioNights()

        XCTAssertEqual(try row(repaired, w).sleepScore, try row(saved, w).sleepScore)
        XCTAssertEqual(try row(repaired, w).stressScore, try row(saved, w).stressScore)
    }

    func testThePassSkipsARingNightAManualEditAndAnEmptyHypnogram() throws {
        let store = try makeStore()
        // The wearer had the ring until three days ago, then switched to the strap.
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: day(3))]))

        // A ring night, unscored: not ours to score (decision 28).
        let ringNight = try XCTUnwrap(try saveRingNight(store, daysAgo: 6, skinTempC: 33.2))
        // A strap night the wearer edited by hand: the wearer's word stands (decision 13).
        let editedWindow = window(daysAgo: 2)
        try storeUnscored(store, editedWindow)
        let edited = try row(store, editedWindow)
        edited.isManuallyEdited = true
        // A strap night with no stored timeline: nothing to score at second precision.
        let bareWindow = window(daysAgo: 1)
        try storeUnscored(store, bareWindow)
        let bare = try row(store, bareWindow)
        bare.hypnogramData = Data()
        try store.context.save()
        _ = try store.ingest(heartRate(editedWindow), device: strap)
        _ = try store.ingest(heartRate(bareWindow), device: strap)
        let before = [fingerprint(ringNight), fingerprint(edited), fingerprint(bare)]

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [])
        XCTAssertEqual([fingerprint(ringNight), fingerprint(edited), fingerprint(bare)], before)
    }

    /// It never overwrites a score that is already there, and never writes a computed 0 over one.
    func testThePassNeverOverwritesAStoredScore() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: strap)
        _ = try store.ingest(hrv(w), device: strap)
        try storeUnscored(store, w, sleepScore: 41, stressScore: 73)
        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [], "a scored night is not a candidate")
        XCTAssertEqual(try row(store, w).sleepScore, 41)
        XCTAssertEqual(try row(store, w).stressScore, 73)

        // Unscored sleep but a stored recovery number: the sleep score lands, the recovery stands.
        let other = window(daysAgo: 2)
        _ = try store.ingest(heartRate(other), device: strap)
        _ = try store.ingest(hrv(other), device: strap)
        try storeUnscored(store, other, stressScore: 12)
        XCTAssertEqual(try store.scoreUnscoredHelioNights().count, 1)
        XCTAssertGreaterThan(try row(store, other).sleepScore, 0)
        XCTAssertEqual(try row(store, other).stressScore, 12)
    }

    /// A night the strap recorded but can't be described as sleep gets no score, not a 0 written
    /// back — and the pass does not report it as repaired.
    func testANightThatCannotBeScoredIsLeftAlone() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = [SleepSegment(start: w.start, end: w.end, stage: .awake)]
        _ = try store.saveSleepSummary(SleepStaging.summary(extras.hypnogram),
                                       night: SleepNightKey.night(inBedStart: w.start, inBedEnd: w.end),
                                       inBedStart: w.start, inBedEnd: w.end,
                                       sleepOnset: .distantPast, sleepWake: .distantPast,
                                       extras: extras, device: strap)
        let before = fingerprint(try row(store, w))
        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [])
        XCTAssertEqual(fingerprint(try row(store, w)), before)
    }

    /// #259: a sync that dies between the sleep round and the HRV round stores a Sleep Score and no
    /// stress score. The pass fills the recovery number, leaves the Sleep Score exactly as stored,
    /// and a second run changes nothing.
    func testThePassFillsAMissingStressScoreAndKeepsTheStoredSleepScore() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: strap)
        _ = try store.ingest(hrv(w), device: strap)
        // A stored Sleep Score no recomputation would produce, so an overwrite would show.
        try storeUnscored(store, w, sleepScore: 13)

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [try row(store, w).night])
        let repaired = try row(store, w)
        XCTAssertEqual(repaired.sleepScore, 13, "a stored Sleep Score is never recomputed over")
        XCTAssertEqual(repaired.stressScore, SleepStress.overnightScore(rmssd: [41, 44, 47]))
        let before = fingerprint(repaired)

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [], "idempotent")
        XCTAssertEqual(fingerprint(try row(store, w)), before)
    }

    /// #259: a candidate whose missing score still can't be computed (a scored night with no HRV)
    /// is left byte-identical, `updatedAt` included, and is not reported as changed.
    func testACandidateThatGainsNothingKeepsItsUpdatedAt() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: strap)
        try storeUnscored(store, w, sleepScore: 64)
        let before = fingerprint(try row(store, w))

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [])
        XCTAssertEqual(fingerprint(try row(store, w)), before, "nothing moved, including updatedAt")
    }

    /// #259: one summary breadcrumb per pass, not one per night.
    func testThePassWritesOneSummaryBreadcrumb() throws {
        let store = try makeStore()
        for k in 1...3 {
            let w = window(daysAgo: k)
            _ = try store.ingest(hrv(w), device: strap)
            try storeUnscored(store, w)
        }
        let start = Date()
        XCTAssertEqual(try store.scoreUnscoredHelioNights().count, 3)
        let lines = ObservabilityStore().metricRecords(since: start).filter { $0.source == "sleep-score-strap" }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.detail.hasPrefix("SCORED 3 strap night(s)") ?? false)
    }

    /// The pass works on a night from ANY Zepp OS timeline, because `StoredSleepSummary` has no
    /// device column: a stored night can only ever be attributed to a family (decision 28).
    func testASecondStrapsNightIsScoredToo() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: otherStrap)
        _ = try store.ingest(hrv(w), device: otherStrap)
        try storeUnscored(store, w, device: otherStrap)
        XCTAssertEqual(try store.scoreUnscoredHelioNights().count, 1)
        XCTAssertGreaterThan(try row(store, w).sleepScore, 0)
        XCTAssertGreaterThan(try row(store, w).stressScore, 0)
    }

    // MARK: Decision 29 — the baseline is the strap's own nights

    /// The ring measures on the finger and the strap on the arm, so a ring night's temperature must
    /// never enter the strap's baseline. Here the ring's nights sit 1.5 °C below the strap's: mixed
    /// in, they would drag the baseline down until tonight read as a large rise, and the score moves.
    func testTheTemperatureBaselineUsesStrapNightsOnly() throws {
        let store = try makeStore()
        // Ring until five days ago, strap since.
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: day(5))]))
        for k in 6...12 { try saveRingNight(store, daysAgo: k, skinTempC: 32.8) }
        for k in 1...4 { try storeStrapNight(store, daysAgo: k, celsius: 34.3) }

        let tonight = window(daysAgo: 0)
        _ = try store.ingest(heartRate(tonight), device: strap)
        _ = try store.ingest(temperatures(tonight, celsius: 34.4), device: strap)
        XCTAssertEqual(try store.saveHelioNight(night(tonight), device: strap), .inserted)
        let stored = try row(store, tonight)
        XCTAssertGreaterThan(stored.skinTempC, 0, "the night has a temperature of its own to compare")

        // The same scorer, told the strap's four prior nights — and then told them mixed with the
        // ring's. The stored score matches the first and not the second.
        func score(_ priors: [SkinTempBaseline.NightlyTemp]) -> Int? {
            StoredNightScore.scores(.init(
                segments: segments(tonight),
                heartRate: heartRate(tonight).map { HRSample(bpm: Int($0.value.rounded()), start: $0.start, end: $0.end) },
                skinTempC: stored.skinTempC, priorNights: priors)).sleepScore
        }
        func priors(_ days: [Int], celsius: Double) -> [SkinTempBaseline.NightlyTemp] {
            days.map {
                let w = window(daysAgo: $0)
                return SkinTempBaseline.NightlyTemp(night: SleepNightKey.night(inBedStart: w.start, inBedEnd: w.end),
                                                    celsius: celsius)
            }
        }
        let strapPriors = priors(Array(1...4), celsius: 34.3)
        let mixedPriors = strapPriors + priors(Array(6...12), celsius: 32.8)
        XCTAssertEqual(stored.sleepScore, score(strapPriors), "the strap's own nights are its usual")
        XCTAssertNotEqual(score(mixedPriors), score(strapPriors),
                          "the ring's finger temperatures would have changed the strap's score")
    }

    /// The repair pass builds the same per-device baseline the save path does.
    func testThePassBaselineUsesStrapNightsOnly() throws {
        let store = try makeStore()
        ownership.install(DeviceOwnershipLog(entries: [.init(family: .zeppOS, since: day(5))]))
        for k in 6...12 { try saveRingNight(store, daysAgo: k, skinTempC: 32.8) }
        for k in 1...4 { try storeStrapNight(store, daysAgo: k, celsius: 34.3) }

        let tonight = window(daysAgo: 0)
        _ = try store.ingest(heartRate(tonight), device: strap)
        try storeUnscored(store, tonight, skinTempC: 34.4)
        _ = try store.scoreUnscoredHelioNights()
        let repaired = try row(store, tonight).sleepScore

        // The same night stored through the save path, with the same rows.
        let saved = try makeStore()
        for k in 6...12 { try saveRingNight(saved, daysAgo: k, skinTempC: 32.8) }
        for k in 1...4 { try storeStrapNight(saved, daysAgo: k, celsius: 34.3) }
        _ = try saved.ingest(heartRate(tonight), device: strap)
        _ = try saved.ingest(temperatures(tonight, celsius: 34.4), device: strap)
        _ = try saved.saveHelioNight(night(tonight), device: strap)
        XCTAssertEqual(repaired, try row(saved, tonight).sleepScore)
    }

    /// #259: an old night is scored against the nights BEFORE it, never the ones after it — the
    /// baseline the save path had when that night was the newest one stored.
    func testThePassBaselineUsesOnlyNightsOlderThanTheOneBeingScored() throws {
        let store = try makeStore()
        // Older strap nights at the night's own temperature, later ones far below it.
        for k in 6...9 { try storeStrapNight(store, daysAgo: k, celsius: 34.4) }
        for k in 1...4 { try storeStrapNight(store, daysAgo: k, celsius: 31.4) }
        let target = window(daysAgo: 5)
        _ = try store.ingest(heartRate(target), device: strap)
        try storeUnscored(store, target, skinTempC: 34.4)

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [try row(store, target).night])

        func priors(_ days: [Int], celsius: Double) -> [SkinTempBaseline.NightlyTemp] {
            days.map {
                let w = window(daysAgo: $0)
                return SkinTempBaseline.NightlyTemp(night: SleepNightKey.night(inBedStart: w.start, inBedEnd: w.end),
                                                    celsius: celsius)
            }
        }
        func sleepScore(_ priors: [SkinTempBaseline.NightlyTemp]) -> Int? {
            StoredNightScore.scores(.init(
                segments: segments(target),
                heartRate: heartRate(target).map { HRSample(bpm: Int($0.value.rounded()), start: $0.start, end: $0.end) },
                skinTempC: 34.4, priorNights: priors)).sleepScore
        }
        let older = priors(Array(6...9), celsius: 34.4)
        let withLater = older + priors(Array(1...4), celsius: 31.4)
        XCTAssertNotEqual(sleepScore(withLater), sleepScore(older),
                          "this test only means something while the later nights would move the score")
        XCTAssertEqual(try row(store, target).sleepScore, sleepScore(older))
    }

    /// A ring night's heart rate and HRV never feed a strap night's score. The ring's catch-up rows
    /// for strap-owned time ARE stored (decision 28 keeps them in the app); they just feed nothing
    /// derived, so the night scores as if there were no heart rate at all.
    func testARingsReadingsNeverFeedAStrapNightsScore() throws {
        let store = try makeStore()
        let w = window(daysAgo: 1)
        // The ring's catch-up of the same window, at a very different heart rate and HRV.
        _ = try store.ingest(heartRate(w, bpm: 92), device: .ringConn)
        _ = try store.ingest(hrv(w, ms: [12, 13, 14]), device: .ringConn)
        try storeUnscored(store, w)

        XCTAssertEqual(try store.scoreUnscoredHelioNights().count, 1)
        let scored = try row(store, w)
        XCTAssertEqual(scored.stressScore, 0, "the ring's HRV is not the strap's overnight recovery")
        XCTAssertEqual(scored.sleepScore, StoredNightScore.scores(.init(segments: segments(w))).sleepScore,
                       "no heart-rate factor at all: the ring's 92 bpm never entered the score")
    }

    // MARK: Ring-only users are byte-identical

    func testWithAnEmptyOwnershipLogNoRowIsTouched() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: .ringConn)
        _ = try store.ingest(hrv(w), device: .ringConn)
        let ring = try XCTUnwrap(try saveRingNight(store, daysAgo: 1, skinTempC: 33.4))
        XCTAssertEqual(ring.sleepScore, 0)
        let before = fingerprint(ring)

        XCTAssertEqual(try store.scoreUnscoredHelioNights(), [])
        XCTAssertEqual(fingerprint(try row(store, w)), before)
    }

    /// With an empty log the save path scores nothing either: every night is the ring's, and the
    /// ring scores its own nights.
    func testWithAnEmptyOwnershipLogTheSavePathScoresNothing() throws {
        ownership.install(DeviceOwnershipLog())
        let store = try makeStore()
        let w = window(daysAgo: 1)
        _ = try store.ingest(heartRate(w), device: strap)
        _ = try store.ingest(hrv(w), device: strap)
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments(w)
        store.applyHelioNightScores(to: &extras, window: w, segments: segments(w), device: strap)
        XCTAssertEqual(extras.sleepScore, 0)
        XCTAssertEqual(extras.stressScore, 0)
    }

    // MARK: Readiness (#97) now has something to anchor on

    /// The card's own arithmetic: `sleepCredited` is `MissedNight.endedToday`, and readiness is
    /// `WellnessBalance.anchoredScore` over the stored night's two scores
    /// (`WellnessBalanceCardView`'s `.task`). With a scored strap night that ended today it returns
    /// a score instead of nil, which is the whole of #246.
    func testReadinessHasAScoreWithAScoredStrapNightThatEndedToday() throws {
        let store = try makeStore()
        let w = lastNightWindow()
        _ = try store.ingest(heartRate(w), device: strap)
        _ = try store.ingest(hrv(w), device: strap)

        // Before the fix this night would be stored unscored, and readiness would be nil.
        try storeUnscored(store, w)
        let unscored = try row(store, w)
        XCTAssertTrue(MissedNight.endedToday(inBedEnd: unscored.inBedEnd, nightKey: unscored.night))
        XCTAssertNil(WellnessBalance.anchoredScore(.init(sleepScore: nil, overnightStress: nil,
                                                         vitalsStatus: nil, activityScore: 60)),
                     "activity alone never synthesises a readiness")

        _ = try store.scoreUnscoredHelioNights()
        let scored = try row(store, w)
        XCTAssertGreaterThan(scored.sleepScore, 0)
        XCTAssertTrue(MissedNight.endedToday(inBedEnd: scored.inBedEnd, nightKey: scored.night),
                      "the card only credits a night that ended today (#147)")
        let readiness = try XCTUnwrap(WellnessBalance.anchoredScore(.init(
            sleepScore: scored.sleepScore,
            overnightStress: scored.stressScore > 0 ? scored.stressScore : nil,
            vitalsStatus: nil, activityScore: nil)))
        XCTAssertGreaterThan(readiness.score, 0)
    }

    // MARK: Helpers

    /// Store a strap night the way builds 59–62 did: hypnogram (and optionally a temperature), no
    /// scores. Deliberately NOT through `saveHelioNight`, which now scores it.
    private func storeUnscored(_ store: LocalStore, _ w: DateInterval, device: SyncDeviceID? = nil,
                               skinTempC: Double = 0, sleepScore: Int = 0, stressScore: Int = 0) throws {
        var extras = LocalStore.SleepNightExtras()
        extras.hypnogram = segments(w)
        extras.skinTempC = skinTempC
        extras.sleepScore = sleepScore
        extras.stressScore = stressScore
        let sleep = SleepStaging.sleepWindow(extras.hypnogram)
        _ = try store.saveSleepSummary(SleepStaging.summary(extras.hypnogram),
                                       night: SleepNightKey.night(inBedStart: w.start, inBedEnd: w.end),
                                       inBedStart: w.start, inBedEnd: w.end,
                                       sleepOnset: sleep?.onset ?? .distantPast,
                                       sleepWake: sleep?.wake ?? .distantPast,
                                       extras: extras, device: device ?? strap)
    }

    /// A strap night `daysAgo` days ago with a stored nightly temperature, for the baseline pool.
    private func storeStrapNight(_ store: LocalStore, daysAgo: Int, celsius: Double) throws {
        try storeUnscored(store, window(daysAgo: daysAgo), skinTempC: celsius, sleepScore: 70)
    }

    /// Every column this work is allowed to change, plus the ones it must not.
    private func fingerprint(_ row: StoredSleepSummary) -> String {
        "\(row.night.timeIntervalSince1970) \(row.sleepScore) \(row.stressScore) \(row.skinTempC) "
        + "\(row.asleepMin) \(row.awakeMin) \(row.efficiency) \(row.hypnogramData.count) "
        + "\(row.isManuallyEdited) \(row.updatedAt.timeIntervalSince1970)"
    }
}
