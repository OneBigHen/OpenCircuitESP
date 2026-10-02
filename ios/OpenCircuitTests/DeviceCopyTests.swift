import XCTest
import ZeppKit
@testable import OpenCircuit

/// Decision 51e: device copy is data. The composed text for today's two devices is pinned word for
/// word, and two guards over `allCases` keep a new device's copy complete and its own.
@MainActor
final class DeviceCopyTests: XCTestCase {
    // MARK: the list composer

    func testTheListComposerJoinsLikeTheAppsCopy() {
        XCTAssertEqual(DeviceCopy.list([]), "")
        XCTAssertEqual(DeviceCopy.list(["A"]), "A")
        XCTAssertEqual(DeviceCopy.list(["A", "B"]), "A or B")
        XCTAssertEqual(DeviceCopy.list(["A", "B", "C"]), "A, B or C", "no serial comma")
        XCTAssertEqual(DeviceCopy.list(["A", "B", "C"], "and"), "A, B and C")
    }

    // MARK: composed text, pinned word for word

    func testTheWelcomeLineIsUnchanged() {
        XCTAssertEqual(DeviceCopy.worksWith,
                       "OpenCircuit works with a RingConn ring (Gen 2, Gen 2 Air or Gen 3) or the Amazfit Helio Strap.")
    }

    func testTheBluetoothLineIsUnchanged() {
        XCTAssertEqual(DeviceCopy.bluetoothPermission, "Bluetooth — to find and connect to your ring or strap.")
    }

    func testTheDisclaimerIsUnchanged() {
        XCTAssertEqual(DeviceCopy.disclaimer,
                       "OpenCircuit is an independent, local-first app compatible with RingConn Gen 2, Gen 2 Air and "
                       + "Gen 3 smart rings and the Amazfit Helio Strap. It is not affiliated with, authorized, or "
                       + "endorsed by RingConn, JZ_Tech, Amazfit or Zepp Health; \"RingConn\", \"Amazfit\", \"Helio\" "
                       + "and \"Zepp\" are trademarks of their respective owners. OpenCircuit is not a medical device. "
                       + "Its readings are estimates for personal insight, not diagnosis. Talk to a clinician about any "
                       + "health concern.")
    }

    func testTheAccountBullet() {
        XCTAssertEqual(DeviceCopy.accounts,
                       "No subscription, no cloud. The ring needs no account. The strap needs the Zepp app once, to "
                       + "create its key; after that, OpenCircuit talks only to the strap.")
    }

    func testTheOneAtATimeLine() {
        XCTAssertEqual(DeviceCopy.oneAtATime,
                       "OpenCircuit uses one device at a time. Switching keeps both devices' history on this phone; "
                       + "the other device isn't searched for or connected until you switch back.")
    }

    func testTheCardDetails() {
        XCTAssertEqual(ActiveDeviceChoice.ringConn.cardDetail, "RingConn Gen 2, Gen 2 Air or Gen 3. No account needed.")
        XCTAssertEqual(ActiveDeviceChoice.helioStrap.cardDetail, "Needs a one-time key from the Zepp app (see setup).")
    }

    // MARK: Profile, per device

    func testProfileHealthConnectedLine() {
        XCTAssertEqual(ProfileDeviceCopy.healthWriting(.ringConn), "OpenCircuit is writing your ring's metrics into Apple Health.")
        XCTAssertEqual(ProfileDeviceCopy.healthWriting(.helioStrap), "OpenCircuit is writing your ring's metrics into Apple Health.")
    }

    func testProfileHealthSummary() {
        XCTAssertEqual(ProfileDeviceCopy.healthSummary(.ringConn),
                       "Write your ring's heart rate, HRV, SpO₂, temperature, sleep and more into Apple Health.")
        XCTAssertEqual(ProfileDeviceCopy.healthSummary(.helioStrap),
                       "Write your ring's heart rate, HRV, SpO₂, temperature, sleep and more into Apple Health.")
    }

    func testProfileSleepFocusLine() {
        for device in ActiveDeviceChoice.allCases {
            XCTAssertEqual(ProfileDeviceCopy.sleepFocusNote(device),
                           "Add OpenCircuit to your Sleep Focus once, and turning that Focus off will trigger a ring "
                           + "history sync alongside the existing automatic syncs.")
        }
    }

    func testProfileRemindersFooter() {
        XCTAssertEqual(ProfileDeviceCopy.remindersFooter(.ringConn),
                       "Reminders pause while the ring is on the charger or off your finger — it counts no steps there, "
                       + "so that time isn't treated as sitting still. Quiet hours and backoff use the same settings as "
                       + "health alerts above.")
        XCTAssertEqual(ProfileDeviceCopy.remindersFooter(.helioStrap),
                       "Quiet hours and backoff use the same settings as health alerts above.")
    }

    func testProfileExportAndAlertLines() {
        XCTAssertEqual(ProfileDeviceCopy.exportNote,
                       "Export all stored ring data (HR, SpO₂, sleep, steps) as CSV or JSON for your own analysis. "
                       + "Data stays on your device unless you share it.")
        XCTAssertEqual(ProfileDeviceCopy.alertsDisclaimer,
                       "Note: OpenCircuit is not a medical device. These reminders are based on ring sensor data only "
                       + "and are not a diagnosis. If you feel unwell, consult a qualified medical professional.")
    }

    // MARK: guards over every device

    /// Every string a device's descriptor supplies, including the Profile lines built from it.
    private func copy(of device: ActiveDeviceChoice) -> [String] {
        [device.noun, device.modelPhrase, device.compatibilityPhrase, device.cardDetail, device.accountSentence,
         device.healthSummary, ProfileDeviceCopy.healthWriting(device), ProfileDeviceCopy.sleepFocusNote(device),
         ProfileDeviceCopy.remindersFooter(device)]
            + device.makers + device.trademarks + device.firstSteps
            + [device.setupGuide?.title, device.remindersPauseNote].compactMap { $0 }
    }

    func testEveryDeviceFillsEveryField() {
        for device in ActiveDeviceChoice.allCases {
            XCTAssertFalse(device.makers.isEmpty, "\(device)")
            XCTAssertFalse(device.trademarks.isEmpty, "\(device)")
            XCTAssertFalse(device.firstSteps.isEmpty, "\(device)")
            for text in copy(of: device) {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(device) has an empty field")
            }
        }
    }

    func testNoDevicesCopyNamesAnotherDevicesBrand() {
        for device in ActiveDeviceChoice.allCases {
            for other in ActiveDeviceChoice.allCases where other != device {
                for brand in other.makers + other.trademarks {
                    for text in copy(of: device) {
                        XCTAssertFalse(text.contains(brand), "\(device)'s copy names \(other)'s \(brand): \(text)")
                    }
                }
            }
        }
    }
}
