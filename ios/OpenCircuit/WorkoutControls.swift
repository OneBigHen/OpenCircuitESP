// WorkoutControls.swift — the controls both devices' workout screens share (#283), so the ring's
// `WorkoutView` and the strap's `StrapWorkoutView` behave identically: a hold-to-end button and the
// call-pause coordinator.

import SwiftUI
import CallKit
import Observation
import OpenCircuitKit

// MARK: - Hold to end

/// End button that needs a deliberate hold: a plain tap does nothing but explain, and a fill grows
/// across the button while the finger stays down. Releasing early drains it back. Completing the
/// hold only calls `onHeld` — the caller still asks for confirmation (`.confirmationDialog`), so a
/// mis-hold cannot end a workout either.
///
/// VoiceOver / Switch Control users cannot hold, so the control carries an accessibility action that
/// calls `onHeld` directly; the confirmation dialog is still their safeguard.
struct HoldToEndButton: View {
    static let holdSeconds: Double = 1.0

    let title: String
    let onHeld: () -> Void

    @State private var progress: CGFloat = 0
    @State private var hint = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.18))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 12).fill(Color.red)
                    .frame(width: geo.size.width * progress)
            }
            Label(hint ? "Hold to end" : title, systemImage: "stop.fill")
                .font(.headline)
                .foregroundStyle(progress > 0.5 ? Color.white : Color.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 30, perform: {
            progress = 0
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onHeld()
        }, onPressingChanged: { pressing in
            if pressing {
                withAnimation(.linear(duration: Self.holdSeconds)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        })
        // A tap that is not a hold says what to do instead of silently ignoring the touch.
        .simultaneousGesture(TapGesture().onEnded {
            hint = true
            Task { try? await Task.sleep(for: .seconds(1.5)); hint = false }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Touch and hold to end the workout, or use the activate action.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onHeld() }
    }
}

// MARK: - Call pause

/// Pauses the running workout (ring or strap, whichever is recording) when a phone call connects,
/// and ASKS when it ends — it never resumes by itself, because the person may still be away from the
/// activity. Uses `CXCallObserver` only (call STATE, no entitlement, no call directory / reporting),
/// so it sees calls the system reports through CallKit: cellular, FaceTime, and VoIP apps that
/// integrate CallKit. A VoIP app that does not report to CallKit is invisible to it.
@Observable
@MainActor
final class WorkoutCallPauseCoordinator: NSObject, CXCallObserverDelegate {
    static let shared = WorkoutCallPauseCoordinator()

    /// True while the "paused for a call — resume?" question is on screen.
    var resumePromptVisible = false

    @ObservationIgnored private let observer = CXCallObserver()
    @ObservationIgnored private var tracker = WorkoutCallPause()
    @ObservationIgnored private var wasOnCall = false
    @ObservationIgnored private weak var ring: WorkoutSessionManager?
    @ObservationIgnored private var strap: StrapWorkoutRecorder { .shared }
    @ObservationIgnored private var started = false

    /// Begin observing. Idempotent; `ring` is the app-lifetime ring workout manager.
    func start(ring: WorkoutSessionManager) {
        self.ring = ring
        guard !started else { return }
        started = true
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor [weak self] in self?.evaluate() }
    }

    private var onCall: Bool { observer.calls.contains { $0.hasConnected && !$0.hasEnded } }
    private var running: Bool { (ring?.isRunning ?? false) || strap.isRecording }
    private var paused: Bool { (ring?.isPaused ?? false) || strap.isPaused }

    private func evaluate() {
        let now = onCall
        defer { wasOnCall = now }
        if now && !wasOnCall {
            if tracker.callConnected(workoutRunning: running, workoutPaused: paused) {
                ring?.pause()
                strap.pause()
            }
        } else if !now && wasOnCall {
            if tracker.allCallsEnded(workoutRunning: running, workoutPaused: paused) {
                resumePromptVisible = true
            }
        }
    }

    /// "Resume" on the prompt.
    func resumeAfterCall() {
        resumePromptVisible = false
        tracker.clear()
        ring?.resume()
        strap.resume()
    }

    /// "Stay paused" on the prompt: the person resumes from the workout screen when ready.
    func stayPaused() {
        resumePromptVisible = false
        tracker.clear()
    }
}
