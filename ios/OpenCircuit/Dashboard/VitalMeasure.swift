// The on-demand Measure card's rules (#245, decision 47), lifted out of the Vitals card when that
// card left Today. Nothing here touches SwiftUI, `RingSession` or `HelioSession`: the view reads the
// live devices into the plain fact types below and asks `VitalMeasureState.resolve` what to draw, so
// the enable rules, the settled-HR rule and the "preparing…"/"measuring…" copy can be tested without
// a device — the same shape `StrapLiveHeartRate` already uses for the strap.
//
// These rules are a MOVE, not a rewrite. Each one names the `VitalsTableView` member it came from so
// the behaviour can be diffed against `origin/master`.

import Foundation
import OpenCircuitKit

/// A vital that can be read on demand. Heart rate on either device; SpO₂ on the ring only
/// (decision 30: the strap has no on-demand SpO₂ command).
enum MeasuredVital: String, Hashable, CaseIterable {
    case heartRate, spo2

    /// The stored kind whose latest sample the card shows as "the latest reading".
    var kind: MetricKind {
        switch self {
        case .heartRate: return .heartRate
        case .spo2:      return .spo2
        }
    }

    var title: String {
        switch self {
        case .heartRate: return "Heart Rate"
        case .spo2:      return "SpO₂"
        }
    }

    /// The caveat under the value. SpO₂ is a single-window estimate (🟡, #59), heart rate is not.
    var caveat: String? { self == .spo2 ? "est." : nil }

    /// Formats a LIVE reading, which arrives already in display units (bpm; whole-percent SpO₂).
    func formatLive(_ value: Int) -> String {
        switch self {
        case .heartRate: return "\(value) bpm"
        case .spo2:      return "\(value) %"
        }
    }

    /// Formats a STORED sample, whose SpO₂ is a fraction (0…1) rather than a whole percent.
    func formatStored(_ value: Double) -> String {
        switch self {
        case .heartRate: return "\(Int(value)) bpm"
        case .spo2:      return "\(Int((value * 100).rounded())) %"
        }
    }
}

/// The control the Measure card offers, if any.
enum VitalMeasureControl: Equatable {
    /// The ring's round start/stop control (`VitalsTableView.measureButton`). `active` is a
    /// user-initiated measurement of THIS vital; `enabled` is `measureDisabled()` inverted.
    case ring(active: Bool, enabled: Bool)
    /// The strap's `StrapMeasureButton` (decision 30). It owns its own disabled rule.
    case strap
    /// Nothing to offer: no ready ring, and no strap that can stream.
    case none
}

/// A value + when it was recorded, for the "latest reading" comparison.
struct StampedReading: Equatable {
    var value: Double
    var start: Date

    /// `VitalsTableView.latestReading`, unchanged: the reading to DISPLAY is whichever is more
    /// recent between the persisted store sample and the JUST-SYNCED in-memory batch
    /// (`RingSession.historySamples`, #67) — the sync's newest reading can be newer than anything
    /// the cursor dedup let into the store. After a disconnect the batch is empty, so this falls
    /// back to the store.
    static func newest(stored: StampedReading?, synced: StampedReading?) -> StampedReading? {
        switch (stored, synced) {
        case let (s?, h?): return h.start > s.start ? h : s
        case let (s?, nil): return s
        case let (nil, h?): return h
        case (nil, nil): return nil
        }
    }
}

/// Everything the Measure card reads off `RingSession`, one property per member
/// `VitalsTableView` used, so the rules below stay pure.
struct RingMeasureFacts: Equatable {
    /// `RingSession.ready` — `measureButton` draws nothing at all without it.
    var ready = false

    // `measureDisabled()`'s exact cases, in its order.
    var syncing = false
    var notStreaming = false
    var calibrationCapturing = false
    var capturingHistoricPull = false
    var capturingForensicSweep = false
    var probing = false
    var workoutHolding = false

    // `userMeasureActive(_:)` — the stop button belongs only to a user-initiated measurement;
    // auto-measure and workout cycles keep ownership of the link.
    var userMeasuring = false
    var monitoring = false
    var mode: MeasuredVital = .heartRate

    /// `RingSession.livePreparing` — draining the history backlog before live mode starts (#55).
    var livePreparing = false
    /// `RingSession.liveReadingsStale` — the link has gone quiet, so a lingering live value must
    /// not read as current (#36).
    var liveReadingsStale = false

    /// `RingSession.liveHRTrend`. The user-facing HR is `LiveHR.settled` over this, NEVER the last
    /// frame (one real read spans 82…61 bpm — see `LiveHR.settleSampleCount`).
    var liveHRTrend: [Int] = []
    /// `RingSession.liveHR` — the newest frame, for the big live readout only (what Today's
    /// `liveMeasureCard` shows), never for the card's own value.
    var liveHR: Int?
    /// `RingSession.liveSpO2`, already a whole percent.
    var liveSpO2: Int?

    /// `VitalsTableView.measureDisabled()`, unchanged.
    var measureDisabled: Bool {
        if syncing || notStreaming || calibrationCapturing { return true }
        if capturingHistoricPull || capturingForensicSweep || probing { return true }
        return workoutHolding
    }

    /// `VitalsTableView.userMeasureActive(_:)`, unchanged.
    func userMeasureActive(_ vital: MeasuredVital) -> Bool {
        userMeasuring && monitoring && mode == vital
    }

    /// The value a user-facing read may show: the SETTLED HR window, or the decoded SpO₂ percent.
    func settledValue(_ vital: MeasuredVital) -> Int? {
        switch vital {
        case .heartRate: return LiveHR.settled(liveHRTrend)
        case .spo2:      return liveSpO2
        }
    }

    /// The newest frame, for the live readout.
    func latestFrame(_ vital: MeasuredVital) -> Int? {
        switch vital {
        case .heartRate: return liveHR
        case .spo2:      return liveSpO2
        }
    }
}

/// What the Measure card reads off `StrapLiveHeartRate` (decision 30). Heart rate only.
struct StrapMeasureFacts: Equatable {
    /// `StrapLiveHeartRate.canMeasure` — this connection can start a stream.
    var canMeasure = false
    /// `StrapLiveHeartRate.measuring`.
    var measuring = false
    /// A reading from THIS measurement only, nil while warming up.
    var liveHR: Int?
}

/// What the Measure card draws, decided from the device facts alone. The view adds the latest
/// stored reading (a `@Query`), the live buffer and the buttons' actions.
struct VitalMeasureState: Equatable {
    /// The control to offer.
    var control: VitalMeasureControl = .none
    /// A live stream for THIS vital is running — the live readout and the scrolling chart are
    /// drawn, exactly as Today's `liveMeasureCard` draws them.
    var streaming = false
    /// The number to show INSTEAD of the latest stored reading: nil while the read is still
    /// warming up (`LiveHR.settled` has no answer yet) or while the link has gone stale (#36).
    var liveValue: Int?
    /// The newest frame, for the big live readout only — the same source Today's live card shows,
    /// so the two can never disagree.
    var latestFrame: Int?
    /// "preparing…" / "measuring…", shown in place of the stored reading's age.
    var statusText: String?

    /// The reading's age reads "live" rather than a relative time (`timeFor(_:live:)`).
    var isLive: Bool { liveValue != nil }

    /// The card's decision for `vital`.
    ///
    /// The ring wins whenever a ring session exists, which is the Vitals card's own rule
    /// (`if session == nil, let strapLive { … } else { … }`) — with the ring chosen the strap's
    /// session is never constructed, and vice versa (`ActiveDeviceChoice`).
    static func resolve(_ vital: MeasuredVital, ring: RingMeasureFacts?,
                        strap: StrapMeasureFacts?) -> VitalMeasureState {
        var state = VitalMeasureState()
        if let ring {
            let active = ring.userMeasureActive(vital)
            if ring.ready {
                state.control = .ring(active: active, enabled: !ring.measureDisabled)
            }
            state.streaming = ring.monitoring && ring.mode == vital
            // `liveMeasureCard` treats 0 as "still warming up", not a reading.
            state.latestFrame = state.streaming ? ring.latestFrame(vital).flatMap { $0 > 0 ? $0 : nil } : nil
            let settled = ring.settledValue(vital)
            if active && settled == nil {
                state.statusText = ring.livePreparing ? "preparing…" : "measuring…"
            } else if active && !ring.liveReadingsStale {
                state.liveValue = settled
            }
            return state
        }
        // Decision 30: the strap measures heart rate and nothing else.
        guard let strap, vital == .heartRate else { return state }
        if strap.canMeasure { state.control = .strap }
        state.streaming = strap.measuring
        state.latestFrame = strap.liveHR
        if strap.measuring && strap.liveHR == nil { state.statusText = "measuring…" }
        else { state.liveValue = strap.liveHR }
        return state
    }
}

extension TodayTile.Metric {
    /// The vital this tile's detail can measure on demand (#245). The Resting HR tile is the only
    /// heart-rate tile and its Day view is the day's heart rate, so it carries the heart-rate
    /// Measure card; SpO₂ carries the ring's. The rest have no on-demand read on either device.
    var measuredVital: MeasuredVital? {
        switch self {
        case .restingHR: return .heartRate
        case .spo2:      return .spo2
        case .hrv, .respiratoryRate, .skinTemp, .steps: return nil
        }
    }
}
