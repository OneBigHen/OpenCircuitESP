import AppIntents
import Foundation
import ZeppKit

// The wearable's Shortcuts actions (#260, decision 52). iOS lets no app see other apps' notifications
// or the Clock app's alarms (ZEPP_PROTOCOL.md §13.3), so Shortcuts personal automations are the bridge:
// "When I get a message from …" → Vibrate Wearable; nightly (when Sleep Focus turns on, say) → Set Wake
// Alarm on Wearable, which stores the alarm ON the strap so it fires with no phone needed at wake time.
// The work is in `WearableShortcuts`; these turn parameters into a call and the result into a dialog.
// They are listed in `OpenCircuitAppShortcuts` (HeadacheLogIntent.swift), the app's only provider.
//
// Every action runs in the background (`openAppWhenRun = false`): an automation fires while the phone
// is in a pocket or the person is asleep. And every one runs on a LOCKED phone
// (`authenticationPolicy = .alwaysAllowed`), the same reasoning as `LogHeadacheIntent`: none of them
// discloses anything. Their dialogs say only what was done to the device (a buzz, an alarm time the
// person just typed into the shortcut), never a stored reading. The residual risk, someone with a
// locked phone making the strap buzz or setting its alarm, is physical, visible and reversible, and
// the alternative is an automation that silently fails every night behind a Face ID prompt.

/// How often the wake alarm repeats.
enum WakeAlarmRepeatChoice: String, AppEnum {
    case once
    case everyDay
    case weekdays
    case weekends

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Repeat"
    static let caseDisplayRepresentations: [WakeAlarmRepeatChoice: DisplayRepresentation] = [
        .once: "Once",
        .everyDay: "Every Day",
        .weekdays: "Weekdays",
        .weekends: "Weekends",
    ]

    var days: ZeppAlarmDays {
        switch self {
        case .once: return .once
        case .everyDay: return .everyDay
        case .weekdays: return .weekdays
        case .weekends: return .weekend
        }
    }
}

/// Buzz the wearable in use (decision 52a).
struct VibrateWearableIntent: AppIntent {
    static let title: LocalizedStringResource = "Vibrate Wearable"
    static let description = IntentDescription(
        "Makes the wearable you use with OpenCircuit vibrate. Use it in an automation, for example when you get a message from someone.",
        categoryName: "Wearable",
        searchKeywords: ["vibrate", "buzz", "wearable", "strap", "ring", "notification"])

    /// FALSE on purpose: an automation runs with the phone in a pocket.
    static let openAppWhenRun = false
    /// Runnable on a locked phone: discloses nothing (see the file comment).
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Times", description: "How many buzzes in a row, 1 to 5.", default: 1, inclusiveRange: (1, 5))
    var times: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Vibrate the wearable \(\.$times) time(s)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await WearableShortcuts().vibrate(times: times)
        return .result(dialog: IntentDialog(stringLiteral: result.dialog))
    }
}

/// Store a wake alarm on the wearable itself (decision 52b).
struct SetWakeAlarmOnWearableIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Wake Alarm on Wearable"
    static let description = IntentDescription(
        "Stores a wake alarm on the wearable you use with OpenCircuit, so it vibrates at that time by itself, even with your phone away. Only the time of day is used. OpenCircuit keeps one alarm slot for this and never changes alarms you made yourself.",
        categoryName: "Wearable",
        searchKeywords: ["alarm", "wake", "wake up", "vibrate", "strap", "wearable"])

    static let openAppWhenRun = false
    /// Runnable on a locked phone: discloses nothing (see the file comment).
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @Parameter(title: "Time", description: "The time to wake up. Only its hour and minute are used.")
    var time: Date

    @Parameter(title: "Repeat", default: .once)
    var repeats: WakeAlarmRepeatChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Set a wake alarm on the wearable at \(\.$time)") {
            \.$repeats
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The local hour and minute only: the strap fires in its own local time (§12.3), which the app
        // sets to the phone's on every connection (decision 9).
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let result = await WearableShortcuts().setWakeAlarm(hour: parts.hour ?? 0, minute: parts.minute ?? 0,
                                                            days: repeats.days)
        return .result(dialog: IntentDialog(stringLiteral: result.dialog))
    }
}

/// Remove the wake alarm a Shortcut stored (decision 52c).
struct ClearWakeAlarmOnWearableIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Wake Alarm on Wearable"
    static let description = IntentDescription(
        "Removes the wake alarm that Set Wake Alarm on Wearable stored, if it is still as it was set. Alarms you made yourself are never touched.",
        categoryName: "Wearable",
        searchKeywords: ["alarm", "wake", "clear", "remove", "strap", "wearable"])

    static let openAppWhenRun = false
    /// Runnable on a locked phone: discloses nothing (see the file comment).
    static let authenticationPolicy = IntentAuthenticationPolicy.alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await WearableShortcuts().clearWakeAlarm()
        return .result(dialog: IntentDialog(stringLiteral: result.dialog))
    }
}
