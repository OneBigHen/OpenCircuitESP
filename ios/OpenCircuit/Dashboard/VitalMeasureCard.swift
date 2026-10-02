// The Measure card under a metric detail's chart (#245, decision 47): "when you click the HR card in
// 'your numbers', under the graph, we can have a button to measure".
//
// It is the Vitals card's on-demand half, moved — the ring's round start/stop control, the strap's
// `StrapMeasureButton`, the latest stored reading with its age, and (while a measurement runs) the
// same live readout and scrolling chart Today's `liveMeasureCard` draws. The rules live in
// `VitalMeasure.swift`; this file only renders them.
//
// It shows in EVERY range of `MetricDetailView`, so changing the Day/14/30 picker never takes the
// Measure button away.
//
// ONE live buffer: Today owns `liveBuffer`/`liveRange` and feeds them from the session's live
// readings; this card is handed the same two values. It never opens a feed of its own, so the
// number here and the number on Today cannot disagree.

import SwiftUI
import SwiftData
import OpenCircuitKit

/// What Today hands the detail screen so the Measure card can work: the live devices, and the one
/// live buffer Today already feeds. Optional everywhere — a detail opened without it (DemoData,
/// previews) simply has no card.
struct VitalMeasureSource {
    var session: RingSession?
    var strapLive: StrapLiveHeartRate?
    var buffer = LiveBuffer()
    var range = LiveSessionRange()
#if DEBUG
    /// DEBUG screenshot runs only: a synthetic state, because a simulator has no device to measure
    /// with and the control would otherwise never render. Compiled out of Release — see `DemoData`.
    var demoState: VitalMeasureState?
#endif

    @MainActor
    func state(for vital: MeasuredVital) -> VitalMeasureState {
#if DEBUG
        if let demoState { return demoState }
#endif
        return VitalMeasureState.resolve(vital, ring: session.map(Self.facts(of:)),
                                         strap: strapLive.map(Self.facts(of:)))
    }

    /// Read the ring's live state into plain values. One line per member `VitalsTableView` read.
    @MainActor
    private static func facts(of session: RingSession) -> RingMeasureFacts {
        var f = RingMeasureFacts()
        f.ready = session.ready
        f.syncing = session.syncing
        f.notStreaming = session.notStreaming
        f.calibrationCapturing = session.calibrationCapturing
        f.capturingHistoricPull = session.capturingHistoricPull
        f.capturingForensicSweep = session.capturingForensicSweep
        f.probing = session.probing
        f.workoutHolding = session.workoutHolding
        f.userMeasuring = session.userMeasuring
        f.monitoring = session.monitoring
        f.mode = session.liveMode == .spo2 ? .spo2 : .heartRate
        f.livePreparing = session.livePreparing
        f.liveReadingsStale = session.liveReadingsStale
        f.liveHRTrend = session.liveHRTrend
        f.liveHR = session.liveHR
        f.liveSpO2 = session.liveSpO2
        return f
    }

    @MainActor
    private static func facts(of live: StrapLiveHeartRate) -> StrapMeasureFacts {
        StrapMeasureFacts(canMeasure: live.canMeasure, measuring: live.measuring, liveHR: live.liveHR)
    }
}

/// The Measure card itself.
struct VitalMeasureCard: View {
    let vital: MeasuredVital
    let source: VitalMeasureSource

    /// The latest stored sample for this vital (newest first, capped at 1) — the same bounded
    /// `fetchLimit = 1` descriptor the Vitals card used, so "the latest reading" is unchanged (#32).
    @Query private var latestStored: [StoredSample]

    init(vital: MeasuredVital, source: VitalMeasureSource) {
        self.vital = vital
        self.source = source
        _latestStored = Query(Self.latestDescriptor(vital.kind.rawValue))
    }

    /// Newest-first, single-row descriptor for one metric kind. `value > 0` so a 0-bpm placeholder
    /// (e.g. an EpochSync HR placeholder) can't become the displayed "latest" reading. (#32)
    private static func latestDescriptor(_ kindRaw: String) -> FetchDescriptor<StoredSample> {
        var d = FetchDescriptor<StoredSample>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.value > 0 },
            sortBy: [SortDescriptor(\.start, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    private var state: VitalMeasureState { source.state(for: vital) }

    var body: some View {
        let state = self.state
        // Nothing to offer and nothing live to show: no empty card on a device that can't measure.
        if state.control == .none && !state.streaming {
            EmptyView()
        } else {
            OCCard {
                OCSectionHeader("Measure", systemImage: vital == .heartRate ? "heart.fill" : "lungs.fill",
                                tint: vital == .heartRate ? Theme.hr : Theme.spo2)
                readingRow(state)
                if state.streaming {
                    LiveVitalReadout(value: state.latestFrame, unit: vital == .heartRate ? "bpm" : "%",
                                     tint: vital == .heartRate ? Theme.hr : Theme.spo2,
                                     pulses: vital == .heartRate, sessionRange: source.range)
                    LiveVitalsChart(buffer: source.buffer,
                                    color: vital == .heartRate ? Theme.hr : Theme.spo2,
                                    window: 90,
                                    unit: vital == .heartRate ? "bpm" : "%",
                                    emptyText: "Hold still — getting a reading…")
                        .frame(height: 150)
                    if case .strap = state.control {
                        Text(StrapLiveHeartRate.durationCopy).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The Vitals card's `measurableRow` / `spo2Row`, unchanged: label, value, age (or the
    /// "preparing…"/"measuring…" copy), and the control.
    private func readingRow(_ state: VitalMeasureState) -> some View {
        HStack(spacing: 10) {
            Text(vital.title).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(valueText(state)).font(.subheadline.weight(.semibold)).monospacedDigit()
                if let caveat = vital.caveat {
                    Text(caveat).font(.caption2).foregroundStyle(.tertiary)
                }
                if let time = timeText(state) {
                    Text(time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            control(state)
        }
    }

    @ViewBuilder
    private func control(_ state: VitalMeasureState) -> some View {
        switch state.control {
        case .ring(let active, let enabled):
            measureButton(active: active, enabled: enabled)
        case .strap:
            if let live = source.strapLive { StrapMeasureButton(live: live) }
        case .none:
            EmptyView()
        }
    }

    /// `VitalsTableView.measureButton`, unchanged: a small circular start/stop control. Starting one
    /// user measurement can switch between HR and SpO₂; auto/workout/calibration-owned live cycles
    /// are left alone.
    private func measureButton(active: Bool, enabled: Bool) -> some View {
        let color: Color = vital == .heartRate ? .red : .blue
        let icon = vital == .heartRate ? "heart.fill" : "lungs.fill"
        let mode: RingSession.LiveMode = vital == .heartRate ? .hr : .spo2
        return Button {
            if active { source.session?.stopLiveMonitoring() }
            else { source.session?.startMonitoring(mode: mode, userInitiated: true, quickLiveRead: true) }
        } label: {
            Image(systemName: active ? "stop.fill" : icon)
                .font(.caption2.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? color : Color(.systemGray5)))
                .foregroundStyle(active ? .white : color)
                .symbolEffect(.pulse, isActive: active)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(active ? "Stop measuring \(vital.title)" : "Measure \(vital.title)")
    }

    // MARK: The latest reading (`VitalsTableView.latestReading` / `timeFor`)

    private var latestReading: StampedReading? {
        StampedReading.newest(stored: latestStored.first.map { StampedReading(value: $0.value, start: $0.start) },
                              synced: syncedReading)
    }

    /// `VitalsTableView.latestSynced`, narrowed to this card's one kind.
    private var syncedReading: StampedReading? {
        guard let session = source.session else { return nil }
        var newest: StampedReading?
        for s in session.historySamples where s.value > 0 && s.kind == vital.kind {
            if let cur = newest, cur.start >= s.start { continue }
            newest = StampedReading(value: s.value, start: s.start)
        }
        return newest
    }

    private func valueText(_ state: VitalMeasureState) -> String {
        if let live = state.liveValue { return vital.formatLive(live) }
        return latestReading.map { vital.formatStored($0.value) } ?? "—"
    }

    /// `timeFor(_:live:)` behind the "preparing…"/"measuring…" split.
    private func timeText(_ state: VitalMeasureState) -> String? {
        if let status = state.statusText { return status }
        if state.isLive { return "live" }
        guard let r = latestReading else { return nil }
        return Self.rel.localizedString(for: r.start, relativeTo: Date())
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
}
