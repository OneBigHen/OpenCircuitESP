import SwiftUI
import ZeppKit

// The strap's own settings (#228 measurement, #230 alerts): read from the strap and changed on the
// strap, one setting per user action, through `ZeppHealthConfigEditor` (ZEPP_PROTOCOL.md §15.3: a
// fresh read, ONE arg written echoing the group version, `06 01`, a re-read). The strap is the truth:
// the screens show what the strap reports, and the only thing kept on the phone is the last read,
// for display while the strap can't be reached.
//
// Left out on purpose:
// - Heart Rate Push: the spec can't yet say which arg it is (HEALTH `0x05` is 🔴 "probably", §5.5).
// - Inactivity and goal alerts: whether they buzz on the Helio is 🔴 (§13.4).
// - Workout detection (#229): waits for the spec to identify the args (decision 34).

/// The strap's last read settings, per strap, in memory only: shown (read-only) while the strap
/// can't be reached. Never written back and never treated as the setting.
@MainActor
enum HelioSettingsDisplayCache {
    struct Entry: Equatable {
        let config: ZeppHealthConfig
        let readAt: Date
    }

    private static var entries: [String: Entry] = [:]

    static func store(_ config: ZeppHealthConfig, strap: String, at date: Date = Date()) {
        entries[strap] = Entry(config: config, readAt: date)
    }

    static func entry(strap: String) -> Entry? { entries[strap] }
}

/// The plain-language side of the settings screens: labels, values, what each setting does, its
/// battery cost (in words: no figures are known), and why the controls are unavailable.
enum HelioSettingsCopy {

    static func label(_ setting: ZeppHealthSetting) -> String {
        switch setting {
        case .heartRateMonitoring: return "All-day heart rate"
        case .activeHeartRateMonitoring: return "Active heart-rate monitoring"
        case .highAccuracySleep: return "High-accuracy sleep"
        case .sleepBreathingQuality: return "Sleep breathing quality"
        case .stressMonitoring: return "Stress monitoring"
        case .allDaySpO2: return "All-day SpO₂"
        case .highHeartRateAlert: return "High heart rate"
        case .lowHeartRateAlert: return "Low heart rate"
        case .relaxReminder: return "Relax reminder"
        case .lowSpO2Alert: return "Low SpO₂"
        }
    }

    /// What the setting does, then what it costs in battery.
    static func explanation(_ setting: ZeppHealthSetting) -> String {
        switch setting {
        case .heartRateMonitoring:
            return "How often the strap measures your heart rate. Heart rate, resting heart rate and HRV history come from these readings. "
                + "More frequent readings use more battery; Smart lets the strap decide."
        case .activeHeartRateMonitoring:
            return "Measures heart rate more often while you're active. It doesn't decide whether heart rate is recorded: "
                + "the strap records it either way. Uses more battery during activity."
        case .highAccuracySleep:
            return "Uses heart rate to track your sleep in more detail. Uses more battery overnight."
        case .sleepBreathingQuality:
            return "Measures blood oxygen while you sleep. Running the sensor overnight uses more battery."
        case .stressMonitoring:
            return "Estimates stress through the day from extra heart-rate readings, which use more battery. The relax reminder needs it on."
        case .allDaySpO2:
            return "Measures blood oxygen through the day. Running the sensor uses more battery. The low SpO₂ alert needs it on."
        case .highHeartRateAlert:
            return "Buzzes when your heart rate stays above this for 10 minutes while you're at rest. Not during sleep."
        case .lowHeartRateAlert:
            return "Buzzes when your heart rate stays below this for 10 minutes while you're at rest. Not during sleep."
        case .relaxReminder:
            return "Buzzes when your stress stays high for 10 minutes while you're at rest."
        case .lowSpO2Alert:
            return "Buzzes when your blood oxygen stays below this for 10 minutes. Not during sleep."
        }
    }

    /// What goes missing while a recording switch is off; nil when either value is fine.
    static func offConsequence(_ setting: ZeppHealthSetting, _ value: ZeppConfigValue) -> String? {
        let off = value == .bool(false) || value == .byte(0)
        guard off else { return nil }
        switch setting {
        case .heartRateMonitoring: return "Off: heart rate, resting heart rate and HRV history may be missing."
        case .highAccuracySleep: return "Off: sleep stages may be missing."
        case .sleepBreathingQuality: return "Off: sleep respiratory rate may be missing."
        case .stressMonitoring: return "Off: stress will be empty."
        case .allDaySpO2: return "Off: automatic SpO₂ readings will be empty."
        default: return nil
        }
    }

    /// One value as the strap means it.
    static func value(_ value: ZeppConfigValue, for setting: ZeppHealthSetting) -> String {
        switch (setting, value) {
        case (_, .bool(let on)): return on ? "On" : "Off"
        case (_, .byte(0)): return "Off"
        // SPEC-GAP: `ff` = "smart"/automatic is 🟡 (§5.5).
        case (.heartRateMonitoring, .byte(0xff)): return "Smart"
        case (.heartRateMonitoring, .byte(1)): return "Every minute"
        case (.heartRateMonitoring, .byte(let n)): return "Every \(n) min"
        case (.highHeartRateAlert, .byte(let n)): return "Above \(n) bpm"
        case (.lowHeartRateAlert, .byte(let n)): return "Below \(n) bpm"
        case (.lowSpO2Alert, .byte(let n)): return "Below \(n) %"
        default: return "Not reported"
        }
    }

    /// The dependent control's one-line reason.
    static func needs(_ prerequisite: ZeppHealthSetting) -> String {
        "Needs \(label(prerequisite).lowercasedFirst) on. Turn it on in Measurement."
    }

    /// Why the settings can't be changed right now; nil when they can.
    static func blockedReason(status: HelioStatus, sessionCanChange: Bool, offered: Bool?) -> String? {
        switch status.kind {
        case .ready, .syncing:
            if sessionCanChange { return nil }
            return offered == false
                ? "The strap didn't offer its health settings on this connection."
                : "The strap isn't ready for changes yet."
        case .notSetUp, .keyNeeded:
            return "Add the strap's key to change its settings."
        case .keyRejected:
            return "The strap refused the saved key, so its settings can't be changed. Replace the key first."
        case .strapBusy:
            return "Another phone or app seems to hold the strap, so its settings can't be changed. " + HelioStatus.zeppBluetoothCopy
        case .bluetoothOff, .bluetoothDenied:
            return status.title + ". " + (status.detail ?? "")
        case .unsupported:
            return "This strap doesn't offer its settings over Bluetooth."
        case .authenticating, .settingUp:
            return "Getting ready. Settings can be changed once the strap is connected."
        case .searching, .notFound, .connecting, .disconnected:
            return "Connect the strap to change its settings."
        }
    }

    static let alertsHeader = "These are the strap's own alerts: it buzzes by itself when one triggers, even when your phone "
        + "isn't nearby. They're separate from OpenCircuit's notifications."
    static let savedOnStrap = "Saved on the strap itself. OpenCircuit changes a setting only when you do."
    static let heartRatePushNote = "Heart Rate Push isn't here yet: which strap setting it is hasn't been confirmed. "
        + "OpenCircuit doesn't need it once the key is saved."
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// The state both settings screens share: the strap's values (live, or last read for display), and
/// whether they can be changed.
@MainActor
private struct HelioSettingsModel {
    let connection: HelioConnection
    let status: HelioStatus

    var session: HelioSession? { connection.session }
    var editor: ZeppHealthConfigEditor? { session?.healthConfigEditor }
    var canChange: Bool { session?.canUseHealthSettings == true }
    var blockedReason: String? {
        HelioSettingsCopy.blockedReason(status: status, sessionCanChange: canChange, offered: editor?.isOffered)
    }
    var isBusy: Bool { editor?.isBusy == true }

    /// The live read when there is one; otherwise the last read, for display only.
    var config: ZeppHealthConfig? {
        if canChange, let live = editor?.config { return live }
        return cached?.config
    }

    var cached: HelioSettingsDisplayCache.Entry? {
        (session?.identityID ?? HelioConnection.savedPeripheralID).flatMap { HelioSettingsDisplayCache.entry(strap: $0) }
    }

    /// Showing the last read rather than a read from this connection.
    var showingCache: Bool { !(canChange && editor?.config != nil) && cached != nil }
}

/// One setting: a toggle or a picker of the strap's allowed values, its explanation, and (for a
/// dependent alert) why it is disabled.
private struct HelioSettingRow: View {
    let setting: ZeppHealthSetting
    let config: ZeppHealthConfig
    let enabled: Bool
    let onChange: (ZeppConfigValue, ZeppConfigValue) -> Void

    var body: some View {
        if let current = config.value(setting) {
            let availability = config.availability(setting)
            let usable = enabled && availability == .available
            VStack(alignment: .leading, spacing: 6) {
                control(current: current).disabled(!usable)
                Text(HelioSettingsCopy.explanation(setting)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .needs(let prerequisite) = availability {
                    Text(HelioSettingsCopy.needs(prerequisite)).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                } else if let consequence = HelioSettingsCopy.offConsequence(setting, current) {
                    Text(consequence).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func control(current: ZeppConfigValue) -> some View {
        if setting.isSwitch {
            Toggle(HelioSettingsCopy.label(setting), isOn: Binding(
                get: { current == .bool(true) },
                set: { on in onChange(current, .bool(on)) }))
        } else {
            // The strap's allowed values, in its order; the current value too if the strap reports
            // one outside its own list (shown, never offered as a change).
            let options = config.options(setting) + (config.options(setting).contains(current) ? [] : [current])
            Picker(HelioSettingsCopy.label(setting), selection: Binding(
                get: { current },
                set: { new in onChange(current, new) })) {
                ForEach(options, id: \.self) { option in
                    Text(HelioSettingsCopy.value(option, for: setting)).tag(option)
                }
            }
        }
    }
}

/// Shared shell: the reason the controls are unavailable, the rows, the outcome of the last change.
private struct HelioSettingsList: View {
    let connection: HelioConnection
    let settings: [ZeppHealthSetting]
    let header: String?
    let footer: String
    @State private var hasKey = HelioKeyStore.shared.hasKey
    @State private var keyRejected = HelioKeyStore.shared.isRejected

    private var status: HelioStatus {
        HelioStatus.from(connection: connection.state, phase: connection.session?.phase,
                         hasKey: hasKey, keyRejected: keyRejected,
                         hasSavedStrap: HelioConnection.hasSavedStrap, endedBusy: connection.endedBusy)
    }

    var body: some View {
        let model = HelioSettingsModel(connection: connection, status: status)
        List {
            if let reason = model.blockedReason {
                Section { Text(reason).font(.subheadline) }
            }
            if let header {
                Section { Text(header).font(.subheadline) }
            }
            if let config = model.config {
                Section {
                    ForEach(settings.filter { config.value($0) != nil }, id: \.self) { setting in
                        HelioSettingRow(setting: setting, config: config, enabled: model.canChange && !model.isBusy) { from, to in
                            model.session?.changeHealthSetting(setting, from: from, to: to)
                        }
                    }
                } footer: {
                    if model.showingCache, let cached = model.cached {
                        Text("Last read from the strap \(cached.readAt.formatted(date: .abbreviated, time: .shortened)). " + footer)
                    } else {
                        Text(footer)
                    }
                }
                if settings.allSatisfy({ config.value($0) == nil }) {
                    Section { Text("The strap didn't report these settings.").foregroundStyle(.secondary) }
                }
            } else if model.canChange {
                Section {
                    if case .unreadable? = model.editor?.state {
                        Text("Couldn't read the strap's settings.").foregroundStyle(.secondary)
                        Button("Read again") { model.session?.readHealthSettings() }.disabled(model.isBusy)
                    } else {
                        Text("Reading the strap's settings…").foregroundStyle(.secondary)
                    }
                }
            }
            if model.isBusy, model.editor?.changeInFlight != nil {
                Section { Text("Saving to the strap…").font(.caption) }
            } else if model.canChange, let notice = model.session?.healthSettingsNotice {
                Section { Text(notice).font(.caption) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { model.session?.readHealthSettings() }.disabled(!model.canChange || model.isBusy)
            }
        }
        .onAppear {
            hasKey = HelioKeyStore.shared.hasKey
            keyRejected = HelioKeyStore.shared.isRejected
            model.session?.readHealthSettings()
        }
        .onChange(of: connection.session?.phase) { _, phase in
            if phase == .ready { connection.session?.readHealthSettings() }
        }
    }
}

/// #228: what the strap measures, and how often.
struct HelioMeasurementSettingsView: View {
    let connection: HelioConnection

    var body: some View {
        HelioSettingsList(connection: connection, settings: ZeppHealthSetting.measurement, header: nil,
                          footer: HelioSettingsCopy.savedOnStrap + " " + HelioSettingsCopy.heartRatePushNote)
            .navigationTitle("Measurement")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// #230: the strap's own haptic alerts.
struct HelioAlertsView: View {
    let connection: HelioConnection

    var body: some View {
        HelioSettingsList(connection: connection, settings: ZeppHealthSetting.alerts, header: HelioSettingsCopy.alertsHeader,
                          footer: HelioSettingsCopy.savedOnStrap)
            .navigationTitle("Health alerts")
            .navigationBarTitleDisplayMode(.inline)
    }
}
