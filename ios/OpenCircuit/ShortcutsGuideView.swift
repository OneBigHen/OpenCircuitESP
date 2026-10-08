import SwiftUI

/// In-app guide for the three Shortcuts actions (#285): what each does and one worked recipe.
/// Action names are the shipped App Intent titles in `Wearable/WearableShortcutIntents.swift`.
struct ShortcutsGuideView: View {
    private static let appleGuideURL =
        URL(string: "https://support.apple.com/guide/shortcuts/intro-to-personal-automation-apd690170742/ios")!

    var body: some View {
        List {
            Section {
                Text("OpenCircuit adds three actions to the Shortcuts app. Build them into a personal automation and your wearable reacts without you opening OpenCircuit.")
                Link(destination: Self.appleGuideURL) {
                    Label("Apple: Set up a personal automation", systemImage: "arrow.up.right.square")
                }
            }

            Section("Vibrate Wearable") {
                Text("Makes your wearable vibrate, 1 to 5 times in a row.")
                recipe([
                    "Open Shortcuts and tap Automation, then New Automation.",
                    "Choose Message and pick the sender, for example a family member.",
                    "Choose Run Immediately, then tap Next.",
                    "Tap New Blank Automation, add the action Vibrate Wearable, and set Times.",
                    "Tap Done.",
                ])
            }

            Section("Set Wake Alarm on Wearable") {
                Text("Sets a wake alarm on your wearable for a time of day. Choose Once, Every Day, Weekdays or Weekends. If a Once alarm's time has already passed today, it fires at that time tomorrow instead. Repeating alarms never expire.")
                recipe([
                    "Open Shortcuts, tap Automation, then New Automation.",
                    "Choose Sleep, then Bedtime Begins (or Wind Down), and Run Immediately.",
                    "Add Get All Alarms from the Clock app, then Repeat with Each.",
                    "Inside the repeat, add Filter Alarms by Label, matching the name of your iPhone alarm.",
                    "Add Set Wake Alarm on Wearable. Set Time to the matched alarm's time, and Repeat to Once.",
                    "Tap Done.",
                ])
            }

            Section("Clear Wake Alarm on Wearable") {
                Text("Removes the wake alarm that Set Wake Alarm on Wearable set, if it is still as it was set. Alarms you made yourself are never touched.")
                recipe([
                    "Open Shortcuts, tap Automation, then New Automation.",
                    "Choose Alarm, then When Alarm is Stopped, and Run Immediately.",
                    "Add Clear Wake Alarm on Wearable.",
                    "Tap Done.",
                ])
            }

            Section("Ring and strap differ") {
                Text("Helio Strap: the wake alarm is stored on the strap, which vibrates by itself at that time, even with your phone away.")
                Text("RingConn Gen 3: the wake alarm is driven by the app. It can fire up to 15 minutes late or be missed if the ring isn't connected. A backup notification also fires if the buzz is missed, unless you turned off Backup alert (Profile ▸ Device Info ▸ Vibration & alarm). Keep the ring connected overnight.")
            }
        }
        .navigationTitle("Shortcuts")
    }

    private func recipe(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Example automation").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").font(.callout)
            }
        }
    }
}
