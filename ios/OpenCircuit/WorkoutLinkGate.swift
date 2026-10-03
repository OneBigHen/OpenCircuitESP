// WorkoutLinkGate.swift — when the workout Live Activity's link (`opencircuit://workout/active`) may
// open its sheet, and when it must wait (#258).
//
// A cold launch from the Live Activity while the first-run onboarding cover is still up used to set
// `showWorkout` / `showStrapWorkout` straight away. The sheet tried to present from under the cover,
// forced the cover down for a moment (it is re-presented at once, so onboarding still finished), and
// was itself never shown, leaving `showWorkout` stuck at `true`: the WORKOUT card did nothing for
// the rest of that launch. Now the link is HELD while the cover is up and replayed after it closes,
// after the crash-orphan check, and only once any "Interrupted workout" alert has been answered
// (SwiftUI will not reliably present a sheet and an alert at once).
//
// Pure, so the rules are unit-tested (`WorkoutLinkGateTests`); `ContentView` only applies them.

import Foundation

/// Which workout sheet the link opens: the strap's while a strap workout is recording, else the ring's.
enum WorkoutLinkTarget: Equatable {
    case ring, strap
}

enum WorkoutLinkGate {

    /// What to do with a link that has just arrived.
    enum Action: Equatable {
        /// Open this sheet now.
        case open(WorkoutLinkTarget)
        /// Keep it pending; `replay` opens it later.
        case hold(WorkoutLinkTarget)
    }

    static func target(strapRecording: Bool) -> WorkoutLinkTarget {
        strapRecording ? .strap : .ring
    }

    /// `onboardingCompleted` must be read fresh from `UserDefaults`, never from a captured
    /// `@AppStorage` value (review-256b N1: inside the cover's `onDismiss` that copy is stale).
    static func onLink(onboardingCompleted: Bool, strapRecording: Bool) -> Action {
        let target = target(strapRecording: strapRecording)
        return onboardingCompleted ? .open(target) : .hold(target)
    }

    /// The sheet a pending link may open now, or nil to keep waiting (or when nothing is pending).
    /// Waits while onboarding is unfinished (the cover's `onDismiss` also fires on a forced
    /// dismissal, with the flag still false) and while a recovery alert is waiting for an answer.
    static func replay(pending: WorkoutLinkTarget?, onboardingCompleted: Bool,
                       recoveryAlertShowing: Bool) -> WorkoutLinkTarget? {
        guard let pending, onboardingCompleted, !recoveryAlertShowing else { return nil }
        return pending
    }
}
