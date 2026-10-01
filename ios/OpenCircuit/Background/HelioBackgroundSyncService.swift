import Foundation
import OpenCircuitKit
import UIKit
import ZeppKit

// The Amazfit Helio Strap's background sync (#215 phase 4, decision 26). The strap's counterpart of
// `RingBackgroundSyncService`, entered by the same wakes: the two existing BGTask identifiers and the
// Sleep Focus filter (AppDelegate, SleepFocusSyncFilter). CoreBluetooth state restoration is the
// third leg and needs no code here: `HelioConnection`'s own central relaunches the app, and a
// session that connects then syncs on its own (docs/BACKGROUND_SYNC.md Part B).
//
// One bounded run: connect if needed (by identifier, never a scan) → the session authenticates with
// the Keychain key, sets the clock and fetches (every round acked `03 09`, decision 8, and committed
// to `LocalStore` as it arrives) → flush to Apple Health → one line in the background-run log with a
// "helio strap:" label, plus a `bgphase` breadcrumb (B.4).
//
// Budget (B.3): the fetch gets the task's window minus `flushReserve`. When that runs out, or iOS
// expires the task, the open round is acked `03 09`, what was committed stays committed, the link is
// dropped cleanly (a running find gets its `06` first) and the rest stays on the strap for next time.
// Only an uninterrupted sync is followed by the Health flush inside the window; an abandoned one
// flushes only when the budget (not iOS) ended it. If the app is in front when the budget runs out,
// nothing is torn down: the sync is handed to the app, whose post-sync hook flushes it (review-225 S1).
//
// Key states (decision 7): no key, a rejected key (persisted), or a strap that ended busy earlier in
// this app launch end the run before any radio work; a session that turns out keyless, rejected,
// busy or unsupported ends it quietly. No retry, no Health write, and the log says why. "Busy" lasts
// for the launch only: the next launch (a background relaunch too) tries once more, which is how the
// strap comes back once Zepp lets go of it (review-225 F1).

/// What the background run needs from the strap's connection: `HelioConnection` in the app, a
/// simulated strap in the tests.
@MainActor
protocol HelioBackgroundLink: AnyObject {
    /// The strap's session on the current link, if any.
    var session: HelioSession? { get }
    /// The last connection in this app launch ended with the strap busy (decision 7): nothing
    /// reconnects by itself until the person asks or the app is next launched, so neither does a
    /// background run.
    var endedBusy: Bool { get }
    /// Where the strap's rows live (`zeppos:<id>`): the connected strap's, else the saved one's; nil
    /// when no strap was ever connected.
    var strapTimeline: SyncDeviceID? { get }
    /// Background runs in progress on this link, from the end of a run's turn-wait to its return (0 or
    /// 1: runs take turns, review-225 S2). It only serialises runs; which sessions belong to a run is
    /// `backgroundRunAdoptsNewSessions`. A count, not a flag, so one run's exit can never clear
    /// another's.
    var activeBackgroundRuns: Int { get set }
    /// True only while a run's watch loop runs (review-225b S-A): a session the link creates then is
    /// the run's (`HelioSession.backgroundRunOwnsSyncs`), and the run flushes and logs its syncs. A
    /// session created before or after the loop (during the run's teardown or Health flush, or once
    /// the run is over) flushes and logs its own syncs through the connection's post-sync hook.
    var backgroundRunAdoptsNewSessions: Bool { get set }
    /// A Sleep Focus run that gives up waiting for its turn leaves its "the night is over" here for the
    /// run holding the link (review-225b N-a). That run ORs it into its flush or hand-off, and it is
    /// cleared when that run returns, used or not (review-225c SF-1), so it never reaches a later run.
    /// A waiter that iOS expires leaves nothing.
    var pendingNightsFinalization: Bool { get set }
    /// Arm a connect to the saved strap by identifier (no scan). false when there is none.
    func connectForBackground() -> Bool
    /// End the link cleanly and don't reconnect by itself: stop a running find, ack an open round
    /// `03 09`, then drop the link.
    func disconnectForBackground()
}

/// How one background run ended, for the run log and the task's success flag.
struct HelioBackgroundRun: Equatable {
    enum Ending: Equatable {
        /// A sync ran to its end (`result`; it may have had nothing new).
        case synced
        /// Quiet endings, before or right after auth. No retry, no writes.
        case noSavedStrap
        case keyNeeded
        case keyRejected
        case strapBusy
        /// The strap lacks what the app needs to fetch history.
        case unsupported
        /// The strap didn't connect, or the sync didn't finish, inside the budget: abandoned with
        /// `03 09` and a clean disconnect.
        case outOfTime
        /// iOS expired the task: abandoned the same way, without the Health flush.
        case expired
        /// Out of budget (or expired) while the app was in front: the sync was left running for the
        /// app, whose own post-sync hook flushes and logs it (review-225 S1). Nothing torn down.
        case handedToApp
        /// Another background run held the strap for this run's whole window (review-225 S2). This
        /// run touched nothing; the other one syncs and flushes.
        case anotherRunActive
    }

    var ending: Ending
    /// The last sync that ended during the run (finished or interrupted).
    var result: HelioSyncResult?
    var connectMS: Int?
    var syncMS: Int?
    var flushMS: Int?
    /// Nil when no flush ran (a quiet ending, an expiry, or Health unavailable).
    var flush: HealthKitWriter.FlushResult?
    /// This run acked an open round `03 09` and dropped the link (out of time, or expired).
    var disconnected = false

    /// A quiet ending: nothing was fetched and nothing may be written (decision 7).
    var endedQuietly: Bool {
        switch ending {
        case .noSavedStrap, .keyNeeded, .keyRejected, .strapBusy, .unsupported, .anotherRunActive: return true
        case .synced, .outOfTime, .expired, .handedToApp: return false
        }
    }

    /// The BGTask success flag: an uninterrupted sync, or anything written to Apple Health.
    var success: Bool {
        (ending == .synced && result?.interrupted == false) || flush?.wroteAnything == true
    }

    /// What an out-of-time or expired run did to the link, for its log line.
    private var teardown: String { disconnected ? "; open round kept on the strap (03 09), disconnected" : "" }

    /// The run-log line. Counts only: never a key, a serial number or a health value.
    var detail: String {
        let head: String
        switch ending {
        case .synced: head = result?.interrupted == true ? "sync interrupted" : "synced"
        case .noSavedStrap: head = "no strap saved; nothing to sync"
        case .keyNeeded: head = "key needed; not connecting"
        case .keyRejected: head = "key rejected; not retrying"
        case .strapBusy: head = "strap busy (another phone or app holds it); not retrying"
        case .unsupported: head = "strap doesn't offer history over Bluetooth"
        case .outOfTime: head = "out of time" + teardown
        case .expired: head = "iOS ended the task" + teardown
        case .handedToApp: head = "handed to the app"
        case .anotherRunActive: head = "another background run held the strap for this run's whole window; nothing done"
        }
        var parts = ["helio strap: \(head)"]
        if let result {
            parts.append("\(result.roundsStored) round(s) stored, \(result.roundsFailed) failed, \(result.nights.count) night(s)")
        }
        if let flush { parts.append("Health samples=\(flush.samples) sleep=\(flush.sleepSegments) steps=\(flush.steps)") }
        return parts.joined(separator: "; ")
    }

    /// The `bgphase` breadcrumb (B.4), in the ring's shape plus `device=helio`.
    func breadcrumb(kind: TaskRecord.Kind) -> String {
        func ms(_ value: Int?) -> String { value.map { "\($0)ms" } ?? "n/a" }
        return "device=helio kind=\(kind.rawValue) ending=\(ending) connect=\(ms(connectMS)) sync=\(ms(syncMS))"
            + " flush=\(ms(flushMS)) rounds=\(result?.roundsStored ?? 0) failed=\(result?.roundsFailed ?? 0)"
            + " mirrored=\(flush?.wroteAnything ?? false)"
    }
}

@MainActor
struct HelioBackgroundSyncService {
    /// Kept back from the task's window for the Apple Health flush and the teardown, so the flush
    /// doesn't start when iOS is about to expire the task (the ring's app-refresh runs were cut
    /// mid-flush 11 times in 15 before its flush-first fix, #119).
    static let flushReserve: TimeInterval = 8
    /// How long the teardown waits for the `03 09` and a find `06` to leave the radio before the
    /// flush (`HelioConnection.disconnect` cancels the link after 0.5 s).
    static let teardownGrace: TimeInterval = 0.6

    let link: any HelioBackgroundLink
    let keyStore: any HelioKeyStoring
    let observability: ObservabilityStore
    /// The strap's Apple Health pass (`HelioConnection.healthFlush` in the app, the post-sync hook's
    /// own): the rows of `timeline`, attributed from the row and the strap's `identity`, never from
    /// the current device choice (decision 28).
    let flush: @MainActor (_ timeline: SyncDeviceID, _ nights: [HelioSleepSelection.Night],
                           _ identity: WearableIdentity?, _ finalized: Bool) async -> HealthKitWriter.FlushResult?
    let now: @MainActor () -> Date
    /// One wait between checks (250 ms in the app; the tests move the simulated strap along instead).
    let pause: @MainActor () async -> Void
    /// After an abandoned sync: time for the `03 09` (and a find `06`) to leave the radio before the
    /// link goes. It must also run in a task iOS just expired, so the app's version can't be cancelled.
    let grace: @MainActor () async -> Void
    /// The app is in front (`applicationState == .active`). Then a run that runs out of time hands
    /// its sync to the app instead of tearing down the link the person is now using (review-225 S1).
    let appIsActive: @MainActor () -> Bool

    /// One bounded run. `nightsFinalized` is the Sleep Focus wake's "the night is over" signal: the
    /// strap's nights then skip the 20-minute quiet margin, as the ring's do on that wake.
    func run(kind: TaskRecord.Kind, timeout: TimeInterval, nightsFinalized: Bool = false) async -> HelioBackgroundRun {
        let start = now()
        var run = HelioBackgroundRun(ending: .outOfTime)
        let syncDeadline = start.addingTimeInterval(max(0, timeout - Self.flushReserve))

        // Review-225 S2: one run at a time on a link. The Sleep Focus wake and the scheduler's morning
        // refresh can overlap; two runs would adopt the same sync and both flush it (and a
        // non-finalized flush could win over the Focus run's finalized one). A later run waits, inside
        // its own budget, then runs normally: a cheap second sync with its own `nightsFinalized`.
        while link.activeBackgroundRuns > 0 {
            if Task.isCancelled || now() >= syncDeadline {
                // Review-225c SF-1: only a waiter that gave up (not one iOS expired) leaves its request.
                if nightsFinalized, !Task.isCancelled { link.pendingNightsFinalization = true }
                // Review-225b N-c: an expiry while waiting is an expiry (no alert pass follows).
                run.ending = Task.isCancelled ? .expired : .anotherRunActive
                return record(run, kind: kind)
            }
            await pause()
        }

        // Quiet endings before any radio work: nothing is connected and no central is created.
        if link.strapTimeline == nil {
            run.ending = .noSavedStrap
        } else if keyStore.load() == nil {
            run.ending = .keyNeeded
        } else if keyStore.isRejected {
            run.ending = .keyRejected
        } else if link.endedBusy {
            run.ending = .strapBusy
        }
        if run.endedQuietly { return record(run, kind: kind) }

        link.activeBackgroundRuns += 1
        defer {
            link.activeBackgroundRuns -= 1
            // Review-225c SF-1: a waiter's request lives only as long as this run. Unused (this run
            // expired, ended quietly, or was already in its flush), it goes with it, so it can never
            // finalize an unrelated flush hours later.
            link.pendingNightsFinalization = false
        }
        // Review-225b S-A: sessions made from here to the end of the watch loop are this run's. The
        // mark is dropped before anything after the loop awaits (teardown grace, Health flush), so a
        // session made then (the app opened during an abandoned run's teardown) owns its own syncs.
        link.backgroundRunAdoptsNewSessions = true
        defer { link.backgroundRunAdoptsNewSessions = false }

        var watched: HelioSession?
        var baseline = 0
        var requested = false
        var syncStartedAt: Date?
        if link.session?.isLinkConnected != true { _ = link.connectForBackground() }

        loop: while true {
            if Task.isCancelled { run.ending = .expired; break }
            if let session = link.session, session.isLinkConnected {
                if session !== watched {
                    // A connection made during this run (its link marked it) counts every sync it
                    // ran; one that was already up counts only syncs from now on.
                    watched = session
                    baseline = session.backgroundRunOwnsSyncs ? 0 : session.syncsFinished
                    session.backgroundRunOwnsSyncs = true
                    requested = session.syncing || baseline < session.syncsFinished
                    if session.syncing, syncStartedAt == nil { syncStartedAt = now() }
                }
                if session.syncsFinished > baseline, let result = session.lastSyncResult {
                    run.result = result
                    if !session.syncing {
                        run.ending = .synced
                        break loop
                    }
                }
                switch session.phase {
                case .keyless: run.ending = .keyNeeded; break loop
                case .keyRejected: run.ending = .keyRejected; break loop
                case .strapBusy: run.ending = .strapBusy; break loop
                case .unsupported: run.ending = .unsupported; break loop
                case .ready:
                    if run.connectMS == nil { run.connectMS = Self.ms(from: start, to: now()) }
                    if !requested {
                        requested = true
                        session.syncHistory(manual: false)
                        guard session.phase == .syncing else { run.ending = .unsupported; break loop }
                        syncStartedAt = now()
                    }
                case .syncing:
                    if run.connectMS == nil { run.connectMS = Self.ms(from: start, to: now()) }
                    if syncStartedAt == nil { syncStartedAt = now() }
                case .starting, .authenticating, .settingUp:
                    break
                }
            }
            if now() >= syncDeadline { run.ending = .outOfTime; break }
            await pause()
        }
        link.backgroundRunAdoptsNewSessions = false
        if let syncStartedAt, run.ending == .synced { run.syncMS = Self.ms(from: syncStartedAt, to: now()) }

        switch run.ending {
        case .outOfTime where appIsActive(), .expired where appIsActive():
            // Review-225 S1: the person opened the app while this run was syncing (the Sleep Focus
            // wake, then a look at last night). Abandoning would disconnect the strap under the open
            // app, and nothing reconnects it. Hand the sync over instead: the session's own post-sync
            // hook flushes and logs it once it ends (its result is no longer the run's), so there is
            // still exactly one flush, and nothing is sent to the strap here.
            watched?.backgroundRunOwnsSyncs = false
            link.session?.backgroundRunOwnsSyncs = false   // one made during the loop's last turn, not yet watched
            // Review-225b S-B: the Sleep Focus run's "the night is over" goes with the sync, so the
            // hook's flush writes the night without the 20-minute margin, as this run would have.
            if takeNightsFinalized(nightsFinalized) {
                watched?.finalizeNightsOnHandOff = true
                link.session?.finalizeNightsOnHandOff = true
            }
            run.ending = .handedToApp
            return record(run, kind: kind)
        case .synced:
            // Leave the link as it is: an idle, authenticated link costs nothing, the next wake skips
            // connect + auth, and the standing reconnect stays armed for the restoration leg. (The
            // ring re-arms a fresh connect instead; for the strap that reconnects at once and the
            // sync-on-connect would fetch everything a second time.)
            watched?.backgroundRunOwnsSyncs = false
        case .outOfTime, .expired:
            // The teardown's writes get their moment on the radio before anything else runs.
            if abandon() {
                run.disconnected = true
                await grace()
            }
            // Review-225 N4: iOS may expire the task during that grace; then no flush follows.
            if Task.isCancelled { run.ending = .expired }
            if let watched, watched.syncsFinished > baseline, let result = watched.lastSyncResult { run.result = result }
        case .handedToApp, .anotherRunActive:
            // Both return above; neither may touch a link another party is using.
            return record(run, kind: kind)
        case .keyNeeded, .keyRejected, .strapBusy, .unsupported, .noSavedStrap:
            // Decision 7: end here, drop the link and leave it down; the next explicit connect retries.
            link.disconnectForBackground()
            return record(run, kind: kind)
        }

        // The Health flush: never after an expiry (the task is over), never for a quiet ending.
        if run.ending != .expired, let timeline = link.strapTimeline {
            let flushStart = now()
            run.flush = await flush(timeline, run.result?.nights ?? [], run.result?.identity ?? watched?.identity,
                                    takeNightsFinalized(nightsFinalized))
            run.flushMS = Self.ms(from: flushStart, to: now())
            if run.flush?.wroteAnything == true { observability.recordHealthWrite() }
        }
        return record(run, kind: kind)
    }

    /// This run's finalization, ORed with one a waiting Sleep Focus run left on the link (consumed).
    private func takeNightsFinalized(_ own: Bool) -> Bool {
        defer { link.pendingNightsFinalization = false }
        return own || link.pendingNightsFinalization
    }

    /// Ack an open round `03 09` and drop the link (the find stop goes out first). false when no
    /// session is up: a connect still pending stays armed, so the strap coming into range can wake
    /// the app through state restoration later.
    private func abandon() -> Bool {
        guard let session = link.session else { return false }
        session.abortSync()
        link.disconnectForBackground()
        return true
    }

    @discardableResult
    private func record(_ run: HelioBackgroundRun, kind: TaskRecord.Kind) -> HelioBackgroundRun {
        observability.recordSyncOutcome(kind: kind, success: run.success, detail: run.detail)
        observability.recordMetricEvent(source: "bgphase", detail: run.breadcrumb(kind: kind))
        helioLog.notice("\(run.detail, privacy: .public)")
        return run
    }

    private static func ms(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}

extension HelioBackgroundSyncService {
    /// The app's run: the shared connection, the Keychain key, the real Health writer and clock.
    static func live(store: LocalStore) -> HelioBackgroundSyncService {
        let connection = HelioConnection.shared
        connection.setLocalStore(store)
        return HelioBackgroundSyncService(
            link: connection, keyStore: connection.keyStore, observability: ObservabilityStore(),
            flush: { timeline, nights, identity, finalized in
                await HelioConnection.healthFlush(timeline: timeline, store: store, nights: nights,
                                                  identity: identity, nightsFinalized: finalized)
            },
            now: { Date() },
            pause: { try? await Task.sleep(for: .milliseconds(250)) },
            grace: {
                // Not `Task.sleep`: that returns at once in a cancelled (expired) task.
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + teardownGrace) { done.resume() }
                }
            },
            appIsActive: { UIApplication.shared.applicationState == .active })
    }
}
