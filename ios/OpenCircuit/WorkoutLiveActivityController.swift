// WorkoutLiveActivityController.swift — app-side lifecycle for the workout Live Activity.
//
// Thin wrapper over ActivityKit that `WorkoutSessionManager` drives: start on workout begin,
// update as time/calories/HR change, end on stop/cancel. All ActivityKit calls live HERE so the
// manager stays a plain state machine; the pure kcal/avg-HR math it feeds this lives in the Kit
// (`WorkoutSessionAggregator.liveActiveKcal`), unit-tested there.
//
// KEEPING BACKGROUND ALIVE — honest scope: the Live Activity does NOT by itself grant background
// execution. What keeps a locked-phone workout recording is the existing location session
// (`WorkoutSessionManager.startLocation` + the `location` UIBackgroundMode). This controller's
// periodic `update(...)` calls run WITHIN that kept-alive runloop, so the Lock Screen / Dynamic
// Island stay current while the app is backgrounded — and the visible, system-managed activity
// gives the user a clear, honest signal that OpenCircuit is actively recording. It is the
// user-facing companion to the location keep-alive, not a replacement for it.
//
// Availability: the app deploys to iOS 17, so ActivityKit (16.1+) is always present; no per-call
// gate is needed. The only runtime guard is `areActivitiesEnabled` — the user can switch Live
// Activities off in Settings, in which case every method here is a graceful no-op and the workout
// proceeds exactly as before.

import Foundation
import ActivityKit
import OpenCircuitKit

@MainActor
final class WorkoutLiveActivityController {

    // Fully qualified: `Activity` unqualified would resolve to OpenCircuitKit's sleep-detection
    // `Activity` enum (imported above), not ActivityKit's generic Live Activity type.
    private var activity: ActivityKit.Activity<WorkoutActivityAttributes>?

    /// Whether the user has Live Activities enabled for the app (Settings ▸ OpenCircuit).
    private var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// The one place both devices' workouts build the Live Activity's state (#283): the ring's
    /// `WorkoutSessionManager` and the strap's `StrapWorkoutRecorder` pass the same primitives, so the
    /// shared widget cannot tell them apart and they cannot drift. `everPaused` keeps the clock on the
    /// plain `startDate` timer for a workout that was never paused (byte-identical to before).
    /// GPS figures arrive already nil for indoor sports / no fix and are passed through untouched;
    /// while paused the pace and zone are dropped (nothing is being measured) and the distance stays.
    static func state(activeSeconds: TimeInterval, activeKcal: Int, bpm: Int?, hrIsStale: Bool,
                      paused: Bool, everPaused: Bool, distanceMeters: Double?,
                      currentPaceSecPerKm: Double?, avgPaceSecPerKm: Double?, hrZone: Int?,
                      now: Date, usesMiles: Bool? = nil) -> WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            elapsedSeconds: activeSeconds, activeKcal: activeKcal,
            bpm: paused ? nil : bpm, hrIsStale: paused || hrIsStale,
            clockStart: everPaused || paused ? now.addingTimeInterval(-activeSeconds) : nil,
            pausedElapsed: paused ? activeSeconds : nil,
            distanceMeters: distanceMeters,
            currentPaceSecPerKm: paused ? nil : currentPaceSecPerKm,
            avgPaceSecPerKm: avgPaceSecPerKm,
            hrZone: paused ? nil : hrZone,
            usesMiles: usesMiles ?? prefersMiles)
    }

    /// The app's distance-unit setting (same key and default as the workout screens), handed to the
    /// widget because the extension cannot read it.
    static var prefersMiles: Bool {
        let raw = UserDefaults.standard.string(forKey: "units.distance") ?? DistanceUnit.localeDefault.rawValue
        return (DistanceUnit(rawValue: raw) ?? .metric) != .metric
    }

    /// True when an activity is currently presented (used to gate updates cheaply).
    var isActive: Bool { activity != nil }

    /// How long a published state stays "fresh". If the app is suspended (e.g. an indoor workout with
    /// no keep-alive) and stops pushing updates, ActivityKit flips `context.isStale` true after this
    /// window so the widget dims a now-frozen reading instead of presenting it as live (#45 honesty).
    /// Set a bit above the ~10 s update heartbeat so a normal gap between updates doesn't false-flag.
    private static let staleAfter: TimeInterval = 20

    /// Begin the Live Activity for a starting workout. No-op (and leaves `activity == nil`) if the
    /// user disabled Live Activities or ActivityKit rejects the request — the workout is unaffected.
    func start(sport: WorkoutSportType, startDate: Date, initial: WorkoutActivityAttributes.ContentState) {
        guard activitiesEnabled, activity == nil else { return }
        let attributes = WorkoutActivityAttributes(
            sportName: sport.displayName,
            sportSymbolName: sport.systemImageName,
            startDate: startDate
        )
        do {
            activity = try ActivityKit.Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial,
                                         staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: nil   // local updates only — no push server (local-first, no cloud)
            )
        } catch {
            // Budget exhausted / disabled between the guard and here / OS refusal — degrade silently.
            activity = nil
        }
    }

    /// Push a fresh dynamic state (elapsed / calories / BPM / staleness). No-op when inactive.
    /// `staleDate` renews the freshness window each push; if pushes stop (app suspended), the widget
    /// flips to `context.isStale` and dims the frozen HR rather than showing it as live.
    func update(_ state: WorkoutActivityAttributes.ContentState) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: state,
                                              staleDate: Date().addingTimeInterval(Self.staleAfter)))
    }

    /// End and immediately dismiss the Live Activity, publishing a final state. No-op when inactive.
    func end(final state: WorkoutActivityAttributes.ContentState) async {
        guard let activity else { return }   // local immutable copy of the current activity
        self.activity = nil                  // clear FIRST so a late in-flight update() slips to a no-op
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
    }

    /// Dismiss any ORPHANED workout Live Activity at app launch. A workout session lives only in
    /// memory, so if the app was force-quit / crashed mid-workout, its Live Activity would otherwise
    /// linger on the Lock Screen with a ticking timer until iOS's own staleness timeout. At a cold
    /// launch no workout can be in progress, so every existing activity for our type is stale — end
    /// them. Called from App.swift's launch `.task`.
    ///
    /// ⚠️ THIS USED TO DESTROY THE LAST EVIDENCE OF THE WORKOUT. Ending the activity was the app's
    /// entire response to a crash mid-workout, so the session — and everything the user had
    /// recorded — went with it, silently (tester report 2026-08-29, build 49). It is safe now
    /// because the evidence no longer lives in the Live Activity: a running session persists a
    /// `WorkoutSessionSnapshot` as it goes, and this function touches ActivityKit ONLY. Nothing
    /// here reads or clears that snapshot, so `ContentView`'s recovery offer is unaffected however
    /// the two launch tasks happen to interleave. Do not add a snapshot teardown here — this runs
    /// at every launch, including the ones that must still recover.
    static func endOrphanedActivitiesAtLaunch() {
        Task {
            for activity in ActivityKit.Activity<WorkoutActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
