import Foundation
import HealthKit
import OpenCircuitKit

// Decision 59 (#277): on iOS 27 and later, every HRV reading the app mirrors to Apple Health is ALSO
// saved to HealthKit's RMSSD type (Health's Recovery HRV), beside the regular-HRV copy (the RMSSD value
// in `.heartRateVariabilitySDNN`, tagged `OpenCircuitHRVStatistic = "RMSSD"`). Both copies come from
// the same stored row; each has its own Health watermark, so one failing never moves or holds the other.

/// The switch for the regular-HRV copy (decision 59c): Profile ▸ Apple Health, on by default, shown
/// only where Recovery HRV exists. Registered at the read site (as `SleepHealthRepublishDefaults` is),
/// because the three writers that flush — foreground, a ring session, a background task — share no
/// launch path. Read at every flush, so all three see the value the user set last.
enum RecoveryHRVDefaults {
    static let writesRegularCopyKey = "health.hrv.writesRegularCopy.v1"

    static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [writesRegularCopyKey: true])
    }

    /// Whether the regular-HRV copy is written where Recovery HRV exists. A missing key reads ON.
    static func writesRegularCopy(_ defaults: UserDefaults = .standard) -> Bool {
        register(defaults)
        return defaults.bool(forKey: writesRegularCopyKey)
    }
}

extension HealthKitWriter {
    /// HealthKit's RMSSD type identifier, by its raw string: the iOS 26.5 SDK this app builds with has
    /// no `.heartRateVariabilityRMSSD` symbol (decision 59, measured).
    static let recoveryHRVIdentifier =
        HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD")

    /// The name the app gives the type, as Health's own section does.
    static let recoveryHRVName = "Recovery HRV"

    /// The RMSSD type where the OS has it, else nil (decision 59a). Only the OPTIONAL lookup: the
    /// non-optional `HKQuantityType(_:)` traps on an identifier the OS doesn't know, and an OS version
    /// number is not what decides it. `lookup` is the seam for tests.
    static func resolveRecoveryHRVType(
        _ lookup: (HKQuantityTypeIdentifier) -> HKQuantityType? = { HKObjectType.quantityType(forIdentifier: $0) }
    ) -> HKQuantityType? {
        lookup(recoveryHRVIdentifier)
    }

    /// This OS's answer, resolved once.
    static let systemRecoveryHRVType: HKQuantityType? = resolveRecoveryHRVType()

    /// Whether a flush for `mirroredKinds` (nil = every mirrored kind, the ring's pass) mirrors HRV at
    /// all: the device's policy gate (`HelioHealthPolicy.healthMirroredKinds()` for the strap), which
    /// both copies sit behind.
    static func mirrorsHRV(_ mirroredKinds: [MetricKind]?) -> Bool {
        mirroredKinds?.contains(.hrvSDNN) ?? true
    }

    /// What one scalar pass saves to each sink (decision 59), decided without a store or `HKHealthStore`.
    struct ScalarWritePlan: Equatable {
        /// The regular copies of every mirrored kind, HRV's tagged copy included while its switch is on.
        var regular: [QuantitySample]
        /// The HRV readings for Recovery HRV.
        var recoveryHRV: [QuantitySample]
    }

    /// The pure rules of decision 59:
    /// - No Recovery HRV type (below iOS 27): the regular copies exactly as pending, the switch ignored
    ///   (there is no switch there), and nothing for Recovery HRV.
    /// - The device's policy doesn't mirror HRV (`mirroredKinds` without `.hrvSDNN`): no Recovery HRV
    ///   either. `regularPending` was already selected by that policy.
    /// - The switch off: HRV leaves the regular copies only, BELOW the policy gate, so Recovery HRV keeps
    ///   going. The held-back rows stay behind the regular watermark, offered again when it's back on.
    ///
    /// `recoveryHRVPending` is the Recovery HRV fetch, called only when both gates above let Recovery HRV
    /// through. So this is the ONE place those gates live: the flush never fetches around them.
    static func scalarWritePlan(regularPending: [QuantitySample],
                                recoveryHRVPending: () -> [QuantitySample],
                                mirroredKinds: [MetricKind]?, recoveryHRVType: HKQuantityType?,
                                writesRegularHRV: Bool) -> ScalarWritePlan {
        guard recoveryHRVType != nil else { return ScalarWritePlan(regular: regularPending, recoveryHRV: []) }
        let regular = writesRegularHRV ? regularPending : regularPending.filter { $0.kind != .hrvSDNN }
        let recovery = mirrorsHRV(mirroredKinds) ? recoveryHRVPending().filter { $0.kind == .hrvSDNN } : []
        return ScalarWritePlan(regular: regular, recoveryHRV: recovery)
    }

    /// One HRV row as its Recovery HRV sample: the stored value in ms, never converted, on the row's own
    /// times, naming `device`. No `OpenCircuitHRVStatistic` tag (the type IS the statistic) and no sync
    /// identifier (decision 59a). Nil for a row that isn't HRV.
    static func recoveryHRVSample(_ s: QuantitySample, type: HKQuantityType,
                                              device: HKDevice?) -> HKQuantitySample? {
        guard s.kind == .hrvSDNN else { return nil }
        let q = HKQuantity(unit: unit(for: .hrvSDNN), doubleValue: s.value)
        return HKQuantitySample(type: type, quantity: q, start: s.start, end: s.end, device: device, metadata: nil)
    }

    /// What `flushScalars` saved, per sink.
    struct ScalarFlushOutcome {
        var regular = ScalarWriteOutcome()
        var recoveryHRV = ScalarWriteOutcome()
    }

    /// The scalar part of `flushToHealth`: the regular copies, then Recovery HRV, each written and THEN
    /// watermarked, each on its own watermark, so a failed save backfills next time and one sink's
    /// failure never holds or moves the other (decision 59b). The write is split per metric (#132): a
    /// denied type doesn't sink the granted ones.
    ///
    /// Called only by `flushToHealth`, which holds the reentrancy guard; tests call it directly.
    func flushScalars(store: LocalStore, device: SyncDeviceID, mirroredKinds: [MetricKind]?,
                      writesRegularHRV: Bool = RecoveryHRVDefaults.writesRegularCopy()) async -> ScalarFlushOutcome {
        var outcome = ScalarFlushOutcome()
        let regularPending = (try? store.pendingHealthSamples(device: device, kinds: mirroredKinds)) ?? []
        let plan = Self.scalarWritePlan(regularPending: regularPending,
                                        recoveryHRVPending: { (try? store.pendingRecoveryHRVHealthSamples(device: device)) ?? [] },
                                        mirroredKinds: mirroredKinds, recoveryHRVType: recoveryHRVType,
                                        writesRegularHRV: writesRegularHRV)
        if !plan.regular.isEmpty {
            outcome.regular = await write(plan.regular, timeline: device)
            if !outcome.regular.written.isEmpty {
                try? store.markHealthWritten(outcome.regular.written, device: device)   // advance ONLY for what actually saved
            }
        }
        if let type = recoveryHRVType, !plan.recoveryHRV.isEmpty {
            outcome.recoveryHRV = await write(plan.recoveryHRV, timeline: device) {
                Self.recoveryHRVSample($0, type: type, device: $1)
            }
            if !outcome.recoveryHRV.written.isEmpty {
                try? store.markRecoveryHRVHealthWritten(outcome.recoveryHRV.written, device: device)
            }
        }
        return outcome
    }
}

/// Profile ▸ Apple Health's row for the regular-HRV switch (decision 59c/59f). The text says what the
/// switch does and nothing more: no claim that Health's Recovery HRV screen shows the readings, which
/// nobody has seen yet (decision 59g).
enum RecoveryHRVCopy {
    /// The row exists only where Recovery HRV does; below iOS 27 there is nothing to switch.
    static func showsSwitch(recoveryHRVType: HKQuantityType?) -> Bool { recoveryHRVType != nil }

    static let switchTitle = "Also write HRV as Heart Rate Variability"

    static let switchFooter = "OpenCircuit writes your HRV to Apple Health as Recovery HRV. With this on, "
        + "it also writes it to the older Heart Rate Variability type, for apps that don't read Recovery HRV "
        + "yet. Turning it off removes nothing already in Apple Health."
}

extension HealthKitWriter.FlushResult {
    /// What the flush log lines add for Recovery HRV (decision 59g: the flush's own log is one of the
    /// proofs on the phone): " recoveryHRV=<n>" when it saved, " recoveryHRV=failed" when its save
    /// threw, and nothing otherwise, so every line is unchanged below iOS 27 and on a pass with
    /// nothing to say.
    var recoveryHRVLogSuffix: String {
        (recoveryHRVSamples > 0 ? " recoveryHRV=\(recoveryHRVSamples)" : "")
            + (recoveryHRVFailed ? " recoveryHRV=failed" : "")
    }

    /// The sync card's opening words. "Synced to Health: N samples" exactly as before, with the
    /// Recovery HRV count named beside it, or alone on a pass that saved only Recovery HRV (the
    /// regular-HRV switch off), never folded into `samples`: the same readings would count twice.
    var syncedToHealthLead: String {
        guard recoveryHRVSamples > 0 else { return "Synced to Health: \(samples) samples" }
        let recovery = "\(recoveryHRVSamples) \(HealthKitWriter.recoveryHRVName)"
        return samples > 0 ? "Synced to Health: \(samples) samples, \(recovery)" : "Synced to Health: \(recovery)"
    }
}
