// Maps parsed Zepp history onto OpenCircuitKit's existing metric kinds — ONLY where the fit is
// clean (docs/HEALTHKIT_MAPPING.md, "Amazfit Helio Strap"). Every other type returns no samples
// and names why in `deferredReason(for:)`; those decisions belong to Phase 3.

import Foundation
import OpenCircuitKit

public enum ZeppMetricMapping {

    /// Quantity samples for one parsed round. Readings the strap marks as "no reading" (HR
    /// `00`/`ff`, temperature sentinels, out-of-range SpO₂) are dropped, never written as 0.
    public static func samples(from parsed: ZeppParsedRecords) -> [QuantitySample] {
        switch parsed.records {
        case .activity(let minutes):
            var out = [QuantitySample]()
            for m in minutes {
                if let bpm = m.heartRate {
                    out.append(QuantitySample(kind: .heartRate, start: m.time, value: Double(bpm)))
                }
                // A real per-minute count (not the ring's quarter-hour bucket): one sample per
                // minute that has steps, spanning that minute.
                if m.steps > 0 {
                    out.append(QuantitySample(kind: .steps, start: m.time,
                                              end: m.time.addingTimeInterval(60), value: Double(m.steps)))
                }
            }
            return out
        case .manualHeartRate(let readings):
            return readings.compactMap { r in
                r.beatsPerMinute.map { QuantitySample(kind: .heartRate, start: r.time, value: Double($0)) }
            }
        case .restingHeartRate(let readings):
            return readings.compactMap { r in
                r.beatsPerMinute.map { QuantitySample(kind: .restingHeartRate, start: r.time, value: Double($0)) }
            }
        case .spo2(let readings):
            return readings.compactMap { r in
                r.percent.map { QuantitySample(kind: .spo2, start: r.time, value: Double($0) / 100) }
            }
        case .temperature(let minutes):
            return minutes.compactMap { m in
                m.celsius.map { QuantitySample(kind: .temperature, start: m.time, value: $0) }
            }
        case .sleepRespiratoryRate(let readings):
            return readings.compactMap { r in
                r.breathsPerMinute > 0
                    ? QuantitySample(kind: .respiratoryRate, start: r.time, value: Double(r.breathsPerMinute))
                    : nil
            }
        case .hrv, .maxHeartRate, .autoStress, .manualStress, .pai, .sleepSpO2, .sleepSession:
            return []
        }
    }

    /// Why a type is not mapped yet; nil for the types `samples(from:)` maps.
    public static func deferredReason(for type: ZeppFetchType) -> String? {
        switch type {
        case .activity, .manualHeartRate, .restingHeartRate, .spo2, .temperature, .sleepRespiratoryRate:
            return nil
        case .hrv:
            return "HRV statistic unknown (RMSSD vs SDNN); .hrvSDNN would assert SDNN"
        case .maxHeartRate:
            return "no HealthKit type for max HR"
        case .autoStress, .manualStress:
            return "no metric kind for stress"
        case .pai:
            return "no metric kind for PAI"
        case .sleepSpO2:
            return "overlaps 0x25 SpO2 (Gadgetbridge does not store it); needs a Phase 3 decision"
        case .sleepSession:
            return "SleepStage has no generic-sleep case and the minute base is unconfirmed; device staging vs SleepStaging is a Phase 3 decision"
        }
    }
}
