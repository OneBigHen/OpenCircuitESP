import XCTest
@testable import OpenCircuit

/// review-237 S1 (#232): the Profile age row must not present the `@AppStorage` placeholder (35) as
/// an age the user entered — the VO₂ max estimate skips until a real age is stored, and tells the
/// user to set it in Profile.
@MainActor
final class ProfileAgeRowTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ProfileAgeRowTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testRowReadsNotSetBeforeAnyWriteAndTheRealAgeAfter() {
        // Never written: the 35 the @AppStorage default supplies is a placeholder.
        XCTAssertEqual(UserProfileSettingsView.ageRowValue(age: 35, defaults: defaults), "Not set")
        // Reading the row must not write the key (display only).
        XCTAssertNil(defaults.object(forKey: "userProfile.age"))

        // A user who really is 35 stores 35, and the row then shows it.
        defaults.set(35, forKey: "userProfile.age")
        XCTAssertEqual(UserProfileSettingsView.ageRowValue(age: 35, defaults: defaults), "35")

        defaults.set(41, forKey: "userProfile.age")
        XCTAssertEqual(UserProfileSettingsView.ageRowValue(age: 41, defaults: defaults), "41")
    }
}
