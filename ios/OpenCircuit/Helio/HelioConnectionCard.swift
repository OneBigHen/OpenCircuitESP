import SwiftUI

/// The Today card while the Helio Strap is the chosen device (#215): connection and key state,
/// battery, last sync, "Sync now", live heart rate when the strap sends it, and the in-app-only
/// readings. It takes the place of the ring's connection card; nothing ring-only is shown.
struct HelioConnectionCard: View {
    let connection: HelioConnection
    var onSetUp: () -> Void = {}

    private var session: HelioSession? { connection.session }

    private var status: HelioStatus {
        HelioStatus.from(connection: connection.state, phase: session?.phase,
                         hasKey: HelioKeyStore.shared.hasKey, keyRejected: HelioKeyStore.shared.isRejected,
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

    /// Only what the strap actually sent (decision 7): nothing, until a reading arrives.
    @ViewBuilder
    private var liveHeartRate: some View {
        if let session {
            if let bpm = session.liveHR, let at = session.liveHRAt, Date().timeIntervalSince(at) < 120 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    KeylineGlyph(.heart, size: 14).foregroundStyle(Theme.hr)
                    Text("\(bpm)").font(.title2.weight(.semibold).monospacedDigit())
                    Text("bpm, live").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.liveHeartRateRunning {
                        Button("Stop") { session.stopLiveHeartRate() }.font(.caption)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if session.canStreamHeartRate, !session.liveHeartRateRunning {
                Button("Live heart rate for a minute") { session.startLiveHeartRate() }
                    .font(.subheadline)
            } else if session.liveHeartRateRunning {
                Text("Waiting for the strap's heart rate…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Stress and PAI (decision 15): shown here, never written to Apple Health.
    @ViewBuilder
    private var appOnlyReadings: some View {
        let result = session?.lastSyncResult
        if result?.latestStress != nil || result?.latestPAI != nil {
            HStack(spacing: 16) {
                if let stress = result?.latestStress {
                    reading("Stress", value: "\(Int(stress.value))", at: stress.at)
                }
                if let pai = result?.latestPAI {
                    reading("PAI", value: "\(Int(pai.value.rounded()))", at: pai.at)
                }
                Spacer()
            }
            Text("Stress and PAI stay in the app: Apple Health has no type for them.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func reading(_ title: String, value: String, at: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
