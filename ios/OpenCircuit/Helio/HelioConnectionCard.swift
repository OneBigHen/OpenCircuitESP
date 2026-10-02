import SwiftUI

/// The Today card while the Helio Strap is the chosen device (#215): connection and key state,
/// battery, last sync, "Sync now", live heart rate when the strap sends it, and the in-app-only
/// readings. It takes the place of the ring's connection card; nothing ring-only is shown.
struct HelioConnectionCard: View {
    let connection: HelioConnection
    var onSetUp: () -> Void = {}
    /// The strap's newest STORED stress reading, under 24 h old (`StrapStressTile.currentReading`), or
    /// nil. Read from the store by ContentView, not from `lastSyncResult`: that is reset at the start of
    /// every sync and set only by that sync's own stress round, so the number used to vanish after any
    /// sync without one and after every relaunch or background wake (#239, steer 3).
    var latestStress: HelioReading?
    /// Opens today's stress chart (#239). The stress reading is a button only when this is set.
    var onStress: (() -> Void)?
    /// The strap's newest STORED PAI reading, under 48 h old (`StrapPAIReading.currentReading`), or
    /// nil. Read from the store by ContentView for exactly the reason stress is: `0x0d` arrives about
    /// once a day, so `lastSyncResult.latestPAI` was blank after almost every sync and after every
    /// relaunch (decision 45).
    var latestPAI: HelioReading?

    /// Cached like `HelioSetupView`'s (review-224 N8): `hasKey` is a Keychain query, so it is read on
    /// appear and whenever the link or session phase moves, not on every render.
    @State private var hasKey = HelioKeyStore.shared.hasKey
    @State private var keyRejected = HelioKeyStore.shared.isRejected

    private var session: HelioSession? { connection.session }

    private func refreshKeyState() {
        hasKey = HelioKeyStore.shared.hasKey
        keyRejected = HelioKeyStore.shared.isRejected
    }

    private var status: HelioStatus {
        HelioStatus.from(connection: connection.state, phase: session?.phase,
                         hasKey: hasKey, keyRejected: keyRejected,
                         hasSavedStrap: HelioConnection.hasSavedStrap,
                         endedBusy: connection.endedBusy)
    }

    var body: some View {
        OCCard {
            HStack(spacing: 8) {
                KeylineGlyph(.activity, size: 16).foregroundStyle(Theme.accent)
                Text("HELIO STRAP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let battery = session?.batteryPercent {
                    Text(session?.charging == true ? "\(battery) %, charging" : "\(battery) %")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("Battery \(battery) percent")
                }
            }
            HelioStatusRow(status: status)
            actions
            liveHeartRate
            appOnlyReadings
            if let warnings = session?.recordingWarnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The strap isn't recording everything").font(.caption.weight(.semibold))
                    ForEach(warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    Text("Turn these on in the Zepp app's health monitoring settings.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { refreshKeyState() }
        .onChange(of: connection.state) { _, _ in refreshKeyState() }
        .onChange(of: session?.phase) { _, _ in refreshKeyState() }
    }

    @ViewBuilder
    private var actions: some View {
        switch status.kind {
        case .notSetUp, .keyNeeded, .keyRejected:
            Button(status.kind == .notSetUp ? "Set up the strap" : "Add the key", action: onSetUp)
                .buttonStyle(.borderedProminent)
        case .notFound, .disconnected, .strapBusy:
            Button("Try again") { connection.reconnectNow() }
                .buttonStyle(.bordered)
        case .ready, .syncing:
            HStack {
                if let last = session?.lastSyncAt {
                    Text("Synced \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let text = session?.syncStatus {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(session?.syncing == true ? "Syncing…" : "Sync now") { session?.syncHistory(manual: true) }
                    .buttonStyle(.bordered)
                    .disabled(session?.syncing == true)
            }
            if let text = session?.syncStatus, session?.lastSyncAt != nil, text != "Synced", text != "Up to date" {
                Text(text).font(.caption2).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    /// Keyless heart rate only (decision 7, Tier 0): what the strap pushes without a key, shown as a
    /// readout, never a control. With the key, live heart rate is the Measure control on the Vitals
    /// card and the Live Heart Rate card, exactly like the ring's (decision 30).
    @ViewBuilder
    private var liveHeartRate: some View {
        if let session, !session.canStreamHeartRate,
           let bpm = session.liveHR, let at = session.liveHRAt, Date().timeIntervalSince(at) < 120 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                KeylineGlyph(.heart, size: 14).foregroundStyle(Theme.hr)
                Text("\(bpm)").font(.title2.weight(.semibold).monospacedDigit())
                Text("bpm, live").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Stress and PAI (decision 15): shown here, never written to Apple Health. Both numbers come
    /// from the store, with their own day-qualified time, so neither depends on what this particular
    /// sync happened to bring.
    @ViewBuilder
    private var appOnlyReadings: some View {
        if latestStress != nil || latestPAI != nil {
            HStack(spacing: 16) {
                if let stress = latestStress {
                    if let onStress {
                        Button(action: onStress) {
                            HStack(alignment: .center, spacing: 4) {
                                reading("Stress", value: "\(Int(stress.value))", at: stress.at,
                                        timeLabel: StrapStressTile.timeLabel(stress.at, now: Date()))
                                KeylineGlyph(.chevronRight, size: 12, relativeTo: .caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens today's stress chart")
                    } else {
                        reading("Stress", value: "\(Int(stress.value))", at: stress.at,
                                timeLabel: StrapStressTile.timeLabel(stress.at, now: Date()))
                    }
                }
                if let pai = latestPAI {
                    reading("PAI", value: "\(Int(pai.value.rounded()))", at: pai.at,
                            timeLabel: StrapStressTile.timeLabel(pai.at, now: Date()))
                }
                Spacer()
            }
            Text("Stress and PAI stay in the app: Apple Health has no type for them.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// `timeLabel` overrides the bare clock time. Stress and PAI both pass the day-qualified label
    /// they share with the Stress tile (`StrapStressTile.timeLabel`), so last night's reading reads
    /// "Yesterday 11:59 PM" instead of a bare clock time under today's date.
    private func reading(_ title: String, value: String, at: Date, timeLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(timeLabel ?? at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
