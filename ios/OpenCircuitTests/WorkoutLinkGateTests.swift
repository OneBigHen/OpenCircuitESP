import XCTest
@testable import OpenCircuit

/// #258: the workout Live Activity link is held under the onboarding cover and replayed after it,
/// behind any "Interrupted workout" alert.
final class WorkoutLinkGateTests: XCTestCase {

    // MARK: arrival

    func testTheLinkOpensTheRingSheetOnceOnboardingIsDone() {
        XCTAssertEqual(WorkoutLinkGate.onLink(onboardingCompleted: true, strapRecording: false), .open(.ring))
    }

    func testTheLinkOpensTheStrapSheetWhileAStrapWorkoutRecords() {
        XCTAssertEqual(WorkoutLinkGate.onLink(onboardingCompleted: true, strapRecording: true), .open(.strap))
    }

    func testUnderTheCoverTheLinkIsHeldNotOpened() {
        XCTAssertEqual(WorkoutLinkGate.onLink(onboardingCompleted: false, strapRecording: false), .hold(.ring))
        XCTAssertEqual(WorkoutLinkGate.onLink(onboardingCompleted: false, strapRecording: true), .hold(.strap))
    }

    // MARK: replay

    func testNothingPendingReplaysNothing() {
        XCTAssertNil(WorkoutLinkGate.replay(pending: nil, onboardingCompleted: true, recoveryAlertShowing: false))
    }

    func testAHeldLinkReplaysOnceTheCoverIsDone() {
        XCTAssertEqual(WorkoutLinkGate.replay(pending: .ring, onboardingCompleted: true, recoveryAlertShowing: false), .ring)
        XCTAssertEqual(WorkoutLinkGate.replay(pending: .strap, onboardingCompleted: true, recoveryAlertShowing: false), .strap)
    }

    func testAForcedDismissalWithOnboardingUnfinishedKeepsWaiting() {
        XCTAssertNil(WorkoutLinkGate.replay(pending: .ring, onboardingCompleted: false, recoveryAlertShowing: false))
    }

    func testTheRecoveryAlertComesFirst() {
        XCTAssertNil(WorkoutLinkGate.replay(pending: .ring, onboardingCompleted: true, recoveryAlertShowing: true))
        XCTAssertNil(WorkoutLinkGate.replay(pending: .strap, onboardingCompleted: true, recoveryAlertShowing: true))
    }
}
