import CoreLocation
import Foundation
import Observation
import OpenCircuitKit
import UIKit

// A workout recorded with the Amazfit Helio Strap (#227, decision 34): the strap's live heart rate
// for the whole workout, the phone's GPS route for outdoor sports, pause and resume, and ONE
// `HKWorkout` attributed to the strap. The ring's workout (`WorkoutSessionManager`, #75/#173) is not
// touched: this recorder is the strap's own, driven through `StrapWorkoutHeartRateSource` (a thin
// adapter over `HelioSession`, as decision 30's `StrapLiveHeartRate` is).
//
// Robustness, each mirroring the ring where the ring has an answer:
//   • background: the same location session the ring's workout uses (outdoor route, or the opt-in
//     indoor keep-alive, `WorkoutSessionManager.indoorKeepAliveEnabledKey`), so the 1 s keep-alive
//     keeps going while the phone is locked. A Measure stream stops on backgrounding; a workout's
//     doesn't (`HelioSession.appDidEnterBackground`).
//   • the app is killed: a journal (`StrapWorkoutJournal` + an append-only reading file) is kept as
//     the workout runs; the next launch offers the workout back, closed at its last reading
//     (`StrapWorkoutRecovery`), like the ring's interrupted-workout offer.
//   • the link drops: the workout keeps running, the gap is recorded in the ledger and shown, and the
//     reconnected session (HelioConnection's standing connect builds a new one) is adopted and its
//     stream started again.
//
// Ring-only users never reach any of this: the recorder is built idle, touches no CoreBluetooth and
// no CoreLocation until a strap workout starts, and its launch checks find no journal.

/// What the recorder needs from a strap connection. `HelioSession` conforms.
@MainActor
protocol StrapWorkoutHeartRateSource: AnyObject {
    var timeline: SyncDeviceID { get }
    var isLinkConnected: Bool { get }
    var ready: Bool { get }
    var syncing: Bool { get }
    var canStreamHeartRate: Bool { get }
    var heartRateObserver: (@MainActor (Int, Date) -> Void)? { get set }
    func startWorkoutHeartRate()
    func stopWorkoutHeartRate()
    func syncHistory(manual: Bool)
}

extension HelioSession: StrapWorkoutHeartRateSource {}

/// One finished strap workout on its way to Apple Health.
struct StrapWorkoutWrite {
    let summary: StrapWorkoutSummary
    /// The readings, each over its own second, inside the running stretches.
    let samples: [HRSample]
    let route: [CLLocation]
    let timeline: SyncDeviceID
}

@MainActor
protocol StrapWorkoutHealthWriting: AnyObject {
    /// One `HKWorkout` (with its heart rate, energy, distance and route). true when it committed.
    func save(_ write: StrapWorkoutWrite) async -> Bool
}

/// The durable journal of a running workout, and the readings still waiting to land in `LocalStore`.
@MainActor
protocol StrapWorkoutJournalStoring: AnyObject {
    func loadJournal() -> StrapWorkoutJournal?
    func saveJournal(_ journal: StrapWorkoutJournal)
    func appendSamples(_ samples: [HRSample])
    func loadSamples() -> [HRSample]
    /// Remove the running workout's journal and readings (not the landing queue).
    func clearRunning()
    func loadLanding() -> [StrapWorkoutLandingBatch]
    func saveLanding(_ batches: [StrapWorkoutLandingBatch])
}

/// Readings of one workout waiting for the strap's history to cover them (`StrapWorkoutHRLanding`).
struct StrapWorkoutLandingBatch: Codable, Equatable {
    var timelineRaw: String
    var samples: [HRSample]
}

/// The phone's location for a workout: the route outdoors, or the indoor keep-alive.
@MainActor
protocol WorkoutLocationTracking: AnyObject {
    var gpsActive: Bool { get }
    var distanceMeters: Double? { get }
    var route: [CLLocation] { get }
    var keepAliveUnavailable: Bool { get }
    /// `route == true`: record the route and distance. false: coarse fixes only to stay alive, never stored.
    func start(route: Bool)
    /// Paused: fixes are not stored and no distance accrues; the session keeps the app alive.
    func setPaused(_ paused: Bool)
    func stop()
}

@Observable
@MainActor
final class StrapWorkoutRecorder {

    enum State: Equatable {
        case idle
        case active
        case finishing
        case finished(StrapWorkoutSummary, savedToHealth: Bool)
        case error(String)
    }

    // MARK: Observable state (the strap's workout screen)

    private(set) var state: State = .idle
    var selectedSport: WorkoutSportType = .runningOutdoor
    /// Running time so far, pauses left out (refreshed every second).
    private(set) var activeSeconds: TimeInterval = 0
    /// The last reading, shown live (also while paused; it is not RECORDED while paused).
    private(set) var currentHR: Int?
    private(set) var currentHRAt: Date?
    private(set) var liveZoneBreakdown = WorkoutZoneBreakdown()
    private(set) var hrSampleCount = 0
    private(set) var ledger: WorkoutActivityLedger?
    /// A workout the previous process was running when it died, offered back (save or discard).
    private(set) var recoverable: RecoveredStrapWorkout?

    var isRecording: Bool { state == .active }
    var isPaused: Bool { ledger?.isPaused == true }
    /// The strap's link is down right now (a gap is being recorded).
    var linkDown: Bool { ledger?.isInGap == true }

    /// The reading is too old to show as live (the strap streams once a second).
    var currentHRIsStale: Bool {
        guard let at = currentHRAt else { return true }
        return clock().timeIntervalSince(at) > Self.staleAfter
    }

    static let staleAfter: TimeInterval = 5

    /// A workout is running in THIS process: the strap's history syncs wait (`HelioSession.syncHistory`),
    /// like the ring's drain waits for its workout (T6). In memory on purpose: a killed process leaves
    /// nothing holding the link.
    static var holdsStrapLink: Bool { running?.isRecording == true }
    private static weak var running: StrapWorkoutRecorder?

    // MARK: Collaborators

    @ObservationIgnored private let source: @MainActor () -> (any StrapWorkoutHeartRateSource)?
    @ObservationIgnored private let health: any StrapWorkoutHealthWriting
    @ObservationIgnored private let journal: any StrapWorkoutJournalStoring
    @ObservationIgnored private let hrStore: @MainActor () -> (any StrapWorkoutHRStore)?
    let location: any WorkoutLocationTracking
    @ObservationIgnored private let liveActivity: WorkoutLiveActivityController?
    @ObservationIgnored private let profile: @MainActor () -> UserProfile
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private let managesIdleTimer: Bool
    @ObservationIgnored private let indoorKeepAlive: () -> Bool

    // MARK: Session state

    @ObservationIgnored private weak var attached: (any StrapWorkoutHeartRateSource)?
    @ObservationIgnored private var timeline: SyncDeviceID?
    @ObservationIgnored private var samples: [HRSample] = []
    @ObservationIgnored private var unjournaled: [HRSample] = []
    @ObservationIgnored private var lastRecordedAt: Date?
    @ObservationIgnored private var profileSnapshot: UserProfile?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    /// Journal heartbeat and Live Activity refresh, the ring's ~10 s cadence.
    static let heartbeatTicks = 10

    init(source: @escaping @MainActor () -> (any StrapWorkoutHeartRateSource)?,
         health: any StrapWorkoutHealthWriting,
         journal: any StrapWorkoutJournalStoring,
         hrStore: @escaping @MainActor () -> (any StrapWorkoutHRStore)?,
         location: any WorkoutLocationTracking,
         liveActivity: WorkoutLiveActivityController?,
         profile: @escaping @MainActor () -> UserProfile = { HealthKitWriter.storedUserProfile() },
         indoorKeepAlive: @escaping () -> Bool = {
             UserDefaults.standard.bool(forKey: WorkoutSessionManager.indoorKeepAliveEnabledKey)
         },
         clock: @escaping () -> Date = Date.init,
         autoTick: Bool = true,
         managesIdleTimer: Bool = true) {
        self.source = source
        self.health = health
        self.journal = journal
        self.hrStore = hrStore
        self.location = location
        self.liveActivity = liveActivity
        self.profile = profile
        self.indoorKeepAlive = indoorKeepAlive
        self.clock = clock
        self.autoTick = autoTick
        self.managesIdleTimer = managesIdleTimer
    }

    /// The app's recorder: the shared strap connection, Apple Health, files in Application Support.
    static func live(store: @escaping @MainActor () -> LocalStore?) -> StrapWorkoutRecorder {
        StrapWorkoutRecorder(source: { HelioConnection.shared.session },
                             health: StrapWorkoutHealthWriter(),
                             journal: StrapWorkoutFileJournal(),
                             hrStore: store,
                             location: StrapWorkoutLocation(),
                             liveActivity: WorkoutLiveActivityController())
    }

    // MARK: Start, pause, resume

    /// Whether Start may be offered: an authenticated strap that can stream, and no sync on the link
    /// (the ring's Start waits for its sync the same way, T1).
    func canStart(_ session: (any StrapWorkoutHeartRateSource)?) -> Bool {
        guard state == .idle, let session else { return false }
        return session.ready && session.canStreamHeartRate && !session.syncing
    }

    func start() {
        guard state == .idle, let session = source(), canStart(session) else { return }
        let now = clock()
        let sport = selectedSport
        Self.running = self
        timeline = session.timeline
        ledger = WorkoutActivityLedger(start: now)
        profileSnapshot = profile()
        samples = []
        unjournaled = []
        lastRecordedAt = nil
        activeSeconds = 0
        currentHR = nil
        currentHRAt = nil
        liveZoneBreakdown = WorkoutZoneBreakdown()
        hrSampleCount = 0
        tickCount = 0
        journal.clearRunning()
        persistJournal(now: now)
        attach(session, now: now)
        if sport.isOutdoor {
            location.start(route: true)
        } else if indoorKeepAlive() {
            location.start(route: false)
        }
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = true }
        state = .active
        helioLog.notice("helio: workout started (\(sport.rawValue, privacy: .public))")
        liveActivity?.start(sport: sport, startDate: now,
                            initial: WorkoutActivityAttributes.ContentState(
                                elapsedSeconds: 0, activeKcal: 0, bpm: nil, hrIsStale: true))
        if autoTick { startTicking() }
    }

    func pause() {
        guard state == .active, var ledger, !ledger.isPaused else { return }
        let now = clock()
        ledger.pause(at: now)
        self.ledger = ledger
        location.setPaused(true)
        refresh(now: now)
        persistJournal(now: now)
        helioLog.notice("helio: workout paused")
        Task { await pushLiveActivity() }
    }

    func resume() {
        guard state == .active, var ledger, ledger.isPaused else { return }
        let now = clock()
        ledger.resume(at: now)
        self.ledger = ledger
        location.setPaused(false)
        refresh(now: now)
        persistJournal(now: now)
        helioLog.notice("helio: workout resumed")
        Task { await pushLiveActivity() }
    }

    // MARK: Time

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.tick(now: self.clock())
            }
        }
    }

    /// Once a second in production; tests call it directly. Follows the link (gap, adoption), keeps
    /// the readings journaled, and on the heartbeat re-stamps the journal and the Live Activity.
    func tick(now: Date) async {
        guard state == .active else { return }
        followLink(now: now)
        flushReadings()
        refresh(now: now)
        tickCount += 1
        if tickCount % Self.heartbeatTicks == 0 {
            persistJournal(now: now)
            await pushLiveActivity()
        }
    }

    private func refresh(now: Date) {
        guard let ledger else { return }
        activeSeconds = ledger.activeSeconds(until: now)
        liveZoneBreakdown = StrapWorkoutSummaryBuilder.zones(samples, ledger: ledger, end: now, maxHR: maxHR)
    }

    private var maxHR: Int { max(220 - max((profileSnapshot ?? profile()).age, 1), 1) }

    // MARK: The link

    /// The attached session lost its link, or HelioConnection replaced it: open a gap. A session that
    /// is back and ready: adopt it, start its stream, close the gap.
    private func followLink(now: Date) {
        guard var ledger else { return }
        let current = source()
        if let attached, attached !== current || !attached.isLinkConnected {
            attached.heartRateObserver = nil
            self.attached = nil
        }
        if attached == nil, !ledger.isInGap {
            ledger.beginGap(at: now)
            helioLog.notice("helio: workout link lost; the workout keeps running")
        }
        self.ledger = ledger
        if attached == nil, let current, current.isLinkConnected, current.ready, current.canStreamHeartRate,
           current.timeline == timeline {
            attach(current, now: now)
        }
    }

    private func attach(_ session: any StrapWorkoutHeartRateSource, now: Date) {
        attached = session
        session.heartRateObserver = { [weak self] bpm, at in self?.receive(bpm: bpm, at: at) }
        session.startWorkoutHeartRate()
        if var ledger, ledger.isInGap {
            ledger.endGap(at: now)
            self.ledger = ledger
            helioLog.notice("helio: workout link back; heart rate restarted")
        }
    }

    /// One reading from the strap. Shown always; recorded only while running, once per instant.
    func receive(bpm: Int, at: Date) {
        guard state == .active, let ledger, LiveHR.validBPM.contains(bpm) else { return }
        currentHR = bpm
        currentHRAt = at
        guard !ledger.isPaused, at > ledger.start, at > (lastRecordedAt ?? .distantPast) else { return }
        lastRecordedAt = at
        let sample = HRSample(bpm: bpm, start: at.addingTimeInterval(-StrapWorkoutSampleLine.span), end: at)
        samples.append(sample)
        unjournaled.append(sample)
        hrSampleCount += 1
    }

    // MARK: End

    /// End the workout: write one `HKWorkout`, queue its readings for `LocalStore`, release the link.
    func end() async {
        guard state == .active, let ledger, let timeline else { return }
        state = .finishing
        let now = clock()
        // Ended while paused: the workout ends where it stopped running.
        let end = ledger.openPauseStart ?? now
        tickTask?.cancel()
        tickTask = nil
        if Self.running === self { Self.running = nil }
        attached?.stopWorkoutHeartRate()
        attached?.heartRateObserver = nil
        attached = nil
        location.stop()
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = false }

        let hasRoute = selectedSport.isOutdoor && !location.route.isEmpty
        let summary = StrapWorkoutSummaryBuilder.summarize(
            sport: selectedSport, ledger: ledger, samples: samples, end: end,
            distanceMeters: hasRoute ? location.distanceMeters : nil, hasRoute: hasRoute,
            profile: profileSnapshot ?? profile())
        let counted = StrapWorkoutSummaryBuilder.activeSamples(samples, ledger: ledger, end: end)

        // Queue the readings for LocalStore BEFORE dropping the journal, so a kill in between loses
        // nothing; then drop the journal BEFORE the Health write, as the ring drops its snapshot: a
        // kill during the write costs this one workout's recovery offer, never a duplicate in Health.
        enqueueLanding(counted, timeline: timeline)
        journal.clearRunning()

        await liveActivity?.end(final: WorkoutActivityAttributes.ContentState(
            elapsedSeconds: summary.activeSeconds,
            activeKcal: Int((summary.summary.estimatedActiveKcal ?? 0).rounded()),
            bpm: summary.summary.avgHR, hrIsStale: true))

        let saved = await health.save(StrapWorkoutWrite(summary: summary, samples: counted,
                                                         route: hasRoute ? location.route : [], timeline: timeline))
        helioLog.notice("helio: workout ended, \(counted.count, privacy: .public) reading(s), saved to Health \(saved, privacy: .public)")
        landPendingHeartRate()
        // The sync the workout held back (T6's re-arm, for the strap).
        if let session = source(), session.ready, !session.syncing { session.syncHistory(manual: false) }
        state = .finished(summary, savedToHealth: saved)
    }

    /// Discard the workout: nothing is written anywhere.
    func cancel() {
        guard state == .active else { return }
        tickTask?.cancel()
        tickTask = nil
        if Self.running === self { Self.running = nil }
        attached?.stopWorkoutHeartRate()
        attached?.heartRateObserver = nil
        attached = nil
        location.stop()
        if managesIdleTimer { UIApplication.shared.isIdleTimerDisabled = false }
        journal.clearRunning()
        let final = WorkoutActivityAttributes.ContentState(elapsedSeconds: activeSeconds, activeKcal: 0,
                                                           bpm: nil, hrIsStale: true)
        Task { await liveActivity?.end(final: final) }
        samples = []
        unjournaled = []
        ledger = nil
        state = .idle
        if let session = source(), session.ready, !session.syncing { session.syncHistory(manual: false) }
    }

    /// Back to the sport picker after the summary (or an error).
    func reset() {
        switch state {
        case .finished, .error: break
        default: return
        }
        state = .idle
        ledger = nil
        samples = []
        activeSeconds = 0
        currentHR = nil
        currentHRAt = nil
        hrSampleCount = 0
        liveZoneBreakdown = WorkoutZoneBreakdown()
    }

    // MARK: Journal

    private func persistJournal(now: Date) {
        guard let ledger, let timeline else { return }
        flushReadings()
        journal.saveJournal(StrapWorkoutJournal(sport: selectedSport, ledger: ledger, lastAliveAt: now,
                                                timelineRaw: timeline.rawValue,
                                                distanceMeters: location.distanceMeters))
    }

    private func flushReadings() {
        guard !unjournaled.isEmpty else { return }
        journal.appendSamples(unjournaled)
        unjournaled = []
    }

    // MARK: Recovery

    /// At launch: offer back a workout the previous process was running when it died. Never while a
    /// workout runs in this process.
    func resolveOrphan(now: Date? = nil) {
        guard state == .idle, recoverable == nil else { return }
        let now = now ?? clock()
        switch StrapWorkoutRecovery.decide(journal: journal.loadJournal(), samples: journal.loadSamples(), now: now) {
        case .nothingToRecover:
            break
        case .discard(let refusal):
            helioLog.notice("helio: discarding an interrupted workout journal (\(refusal.rawValue, privacy: .public))")
            journal.clearRunning()
        case .offer(let recovered):
            helioLog.notice("helio: offering an interrupted workout back")
            recoverable = recovered
        }
    }

    /// Save the interrupted workout: one `HKWorkout` over the recovered span, with its readings. Its
    /// route lived in memory and is gone, so it is saved without one (as the ring's recovery is).
    @discardableResult
    func saveRecovered() async -> Bool {
        guard let recovered = recoverable else { return false }
        recoverable = nil
        let timeline = SyncDeviceID(rawValue: recovered.timelineRaw)
        let summary = StrapWorkoutSummaryBuilder.summarize(
            sport: recovered.sport, ledger: recovered.ledger, samples: recovered.samples, end: recovered.end,
            distanceMeters: nil, hasRoute: false, profile: profile())
        let counted = StrapWorkoutSummaryBuilder.activeSamples(recovered.samples, ledger: recovered.ledger, end: recovered.end)
        enqueueLanding(counted, timeline: timeline)
        journal.clearRunning()   // before the write: a second offer can never write it twice
        let saved = await health.save(StrapWorkoutWrite(summary: summary, samples: counted, route: [], timeline: timeline))
        helioLog.notice("helio: interrupted workout saved to Health \(saved, privacy: .public)")
        landPendingHeartRate()
        return saved
    }

    func discardRecovered() {
        recoverable = nil
        journal.clearRunning()
    }

    /// "Not now": asked again at the next launch.
    func postponeRecovered() {
        recoverable = nil
    }

    // MARK: Heart rate into LocalStore

    private func enqueueLanding(_ samples: [HRSample], timeline: SyncDeviceID) {
        guard !samples.isEmpty else { return }
        var batches = journal.loadLanding()
        batches.append(StrapWorkoutLandingBatch(timelineRaw: timeline.rawValue, samples: samples))
        journal.saveLanding(batches)
    }

    /// Store queued workout readings the strap's history now covers (`StrapWorkoutHRLanding`). Called
    /// after a workout ends, at launch, and after every strap sync.
    func landPendingHeartRate(now: Date? = nil) {
        let batches = journal.loadLanding()
        guard !batches.isEmpty, let store = hrStore() else { return }
        let now = now ?? clock()
        var kept: [StrapWorkoutLandingBatch] = []
        for batch in batches {
            let timeline = SyncDeviceID(rawValue: batch.timelineRaw)
            let split = StrapWorkoutHRLanding.split(batch.samples,
                                                    coveredThrough: store.activityCoveredThrough(timeline: timeline), now: now)
            do {
                if !split.land.isEmpty { try store.insertWorkoutHeartRate(split.land, timeline: timeline) }
                if !split.keep.isEmpty { kept.append(StrapWorkoutLandingBatch(timelineRaw: batch.timelineRaw, samples: split.keep)) }
            } catch {
                helioLog.error("helio: storing workout heart rate failed; kept for next time")
                kept.append(batch)
            }
        }
        if kept != batches { journal.saveLanding(kept) }
    }

    // MARK: Live Activity

    private func pushLiveActivity() async {
        guard let liveActivity, let ledger else { return }
        let now = clock()
        let counted = StrapWorkoutSummaryBuilder.activeSamples(samples, ledger: ledger, end: now)
        let avg = counted.isEmpty ? nil : counted.reduce(0) { $0 + $1.bpm } / counted.count
        let kcal = avg.map {
            Calories.workoutActiveKcal(avgHR: $0, durationSeconds: ledger.activeSeconds(until: now),
                                       profile: profileSnapshot ?? profile())
        } ?? 0
        let active = ledger.activeSeconds(until: now)
        // The Lock Screen clock shows running time: counted up from `now − active` while running,
        // standing still while paused.
        await liveActivity.update(WorkoutActivityAttributes.ContentState(
            elapsedSeconds: active, activeKcal: Int(kcal.rounded()),
            bpm: isPaused ? nil : currentHR, hrIsStale: isPaused || currentHRIsStale,
            clockStart: now.addingTimeInterval(-active), pausedElapsed: isPaused ? active : nil))
    }
}
