import OpenCircuitKit
import SwiftUI
import ZeppKit

/// The Helio Strap's device screen (#215): battery, firmware, last sync, key status, and the
/// controls THIS connection proved it supports (decision 22). A control the strap didn't report is
/// not shown at all, rather than shown disabled.
struct HelioDeviceInfoView: View {
    let connection: HelioConnection
    @State private var confirmDisconnect = false
    @State private var buzzError: String?
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
        List {
            Section {
                HelioStatusRow(status: status)
                LabeledContent("Battery", value: batteryText)
                LabeledContent("Firmware", value: session?.firmwareVersion ?? "Not reported")
                LabeledContent("Hardware", value: session?.hardwareVersion ?? "Not reported")
                LabeledContent("Last sync", value: session?.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                if let text = session?.syncStatus { Text(text).font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Clock", value: session?.clockSet == true ? "Set from this phone" : "Not set on this connection")
            } header: {
                Text("Amazfit Helio Strap")
            }

            Section {
                LabeledContent("Key", value: keyText)
                NavigationLink("Replace or forget the key") { HelioSetupView() }
            } header: {
                Text("Key")
            } footer: {
                Text(HelioStatus.dontUnpairCopy)
            }

            if let session, !controls(session).isEmpty {
                Section {
                    if session.capabilities.contains(.findMyDevice) {
                        NavigationLink("Find My Strap") { FindMyStrapView(connection: connection) }
                    }
                    if session.capabilities.contains(.vibration) {
                        Button(session.isFinding ? "Vibrating…" : "Buzz the strap") {
                            buzzError = session.buzz()
                        }
                        .disabled(session.isFinding)
                        if let buzzError { Text(buzzError).font(.caption).foregroundStyle(.secondary) }
                    }
                    if session.capabilities.contains(.alarm) {
                        NavigationLink("Alarms") { HelioAlarmsView(connection: connection) }
                    }
                } header: {
                    Text("On the strap")
                }
            }

            // #228, #229, #230: the strap's own settings. Always listed: a strap that can't be changed right
            // now shows its controls disabled, with the reason.
            Section {
                NavigationLink("Measurement") { HelioMeasurementSettingsView(connection: connection) }
                if let warnings = session?.recordingWarnings, !warnings.isEmpty {
                    ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                NavigationLink("Health alerts") { HelioAlertsView(connection: connection) }
                NavigationLink("Workout detection") { HelioWorkoutDetectionView(connection: connection) }
            } header: {
                Text("Strap settings")
            } footer: {
                Text(HelioSettingsCopy.savedOnStrap)
            }

            Section {
                if connection.state == .connected || connection.state == .connecting {
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                } else {
                    Button("Connect") { connection.connect() }
                }
                NavigationLink("Use a different device") { DeviceChoiceView() }
            } footer: {
                Text("History stays on this phone either way.")
            }
        }
        .navigationTitle("Helio Strap")
        .onAppear { refreshKeyState() }
        .onChange(of: connection.state) { _, _ in refreshKeyState() }
        .onChange(of: session?.phase) { _, _ in refreshKeyState() }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect the strap?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { connection.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenCircuit stops syncing until you connect again.")
        }
    }

    private var batteryText: String {
        guard let battery = session?.batteryPercent else { return "Not reported" }
        return session?.charging == true ? "\(battery) %, charging" : "\(battery) %"
    }

    private var keyText: String {
        if keyRejected { return "Rejected by the strap" }
        return hasKey ? "Saved" : "Needed"
    }

    private func controls(_ session: HelioSession) -> [String] {
        var out: [String] = []
        if session.capabilities.contains(.findMyDevice) { out.append("find") }
        if session.capabilities.contains(.vibration) { out.append("buzz") }
        if session.capabilities.contains(.alarm) { out.append("alarms") }
        return out
    }
}

/// Find My Strap (decision 18), modelled on `FindMyRingView`: a vibrate control and the Bluetooth
/// signal strength as a distance hint. The strap stops after 60 s; leaving this screen, backgrounding
/// the app, or a link drop sends the stop (the last on the next connection).
struct FindMyStrapView: View {
    let connection: HelioConnection
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    private var session: HelioSession? { connection.session }
    private var rssi: Int? { connection.rssi }
    private var band: RingProximity.Band { RingProximity.band(forRSSI: rssi) }
    private var finding: Bool { session?.isFinding == true }

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)
            dial
            VStack(spacing: 6) {
                Text(band.label).font(.title2.weight(.semibold)).contentTransition(.opacity)
                if let distance = RingProximity.distanceText(forRSSI: rssi) {
                    Text(distance).font(.headline).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Move around the room to pick up a signal.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 12)
            Button {
                if finding { session?.stopFind() } else { error = session?.startFind() }
            } label: {
                Text(finding ? "Stop vibrating" : "Vibrate the strap")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(finding ? .orange : Theme.accent)
            .disabled(session?.ready != true)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            Text("Distance is a rough Bluetooth estimate: walls, your body and how the strap is turned all affect it. "
                 + "The strap stops vibrating after a minute, or when you leave this screen.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal)
        }
        .padding()
        .navigationTitle("Find My Strap")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { connection.startRSSIUpdates() }
        // Backgrounding stopped the find and the signal polling; resume the polling on return.
        .onChange(of: scenePhase) { _, phase in if phase == .active { connection.startRSSIUpdates() } }
        .onDisappear {
            // Decision 18: leaving the screen always stops the find.
            session?.stopFind()
            connection.stopRSSIUpdates()
        }
    }

    private var dial: some View {
        let fraction = RingProximity.signalFraction(forRSSI: rssi)
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.accent.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: fraction)
            KeylineGlyph(.activity, size: 48, relativeTo: .largeTitle)
                .foregroundStyle(finding ? Color.orange : Theme.accent)
        }
        .frame(width: 200, height: 200)
        .padding(.vertical, 8)
        .accessibilityLabel("Signal \(Int(fraction * 100)) percent")
    }
}
