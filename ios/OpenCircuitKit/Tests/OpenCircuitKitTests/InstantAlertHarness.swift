import Foundation
@testable import OpenCircuitKit

/// Drives the instant-alert decision (#73) through repeated evaluate passes, the way
/// `HealthNotificationCenter.evaluate` does: fetch the recent window, decide, route through the ONE
/// shared gate, and mark the ledgers synchronously before anything is posted. SYNTHETIC data only.
///
/// The scenario tests in `LiveHealthAlertsScenarioTests` talk to nothing but this type, so the same
/// scenarios can be replayed against the pre-#234 decision by swapping this file's `pass` body.
final class InstantAlertHarness {
    var hr: [HRSample] = []
    var spo2: [SpO2Reading] = []
    var thresholds = HealthAlertThresholds()
    var quiet = QuietHours(enabled: false)
    let gate = NotificationGate()
    let calendar: Calendar

    /// The anti-spam backoff ledger (`alerts.health.lastFired` in the app).
    private(set) var lastFired: [HealthNotification: Date] = [:]
    /// The once-only ledger (decision 32): the end of the latest reading that notified, per kind.
    private(set) var watermark: [HealthNotification: Date] = [:]
    /// Every notification posted across all passes, in order.
    private(set) var delivered: [HealthAlertHit] = []

    init(calendar: Calendar) { self.calendar = calendar }

    /// One evaluate pass at `now`. Returns what it posted.
    @discardableResult
    func pass(now: Date) -> [HealthAlertHit] {
        // The fetch: the context window back from `now`, minus anything that has not started yet.
        let since = now.addingTimeInterval(-LiveHealthAlerts.contextWindow)
        let hrWindow = hr.filter { $0.start >= since && $0.start <= now }
        let spo2Window = spo2.filter { $0.time >= since && $0.time <= now }

        let live = LiveHealthAlerts.evaluate(hr: hrWindow, spo2: spo2Window, inactiveHR: hrWindow,
                                             thresholds: thresholds, watermark: watermark,
                                             quietHours: quiet, now: now, calendar: calendar)
        let fire = gate.filter(live.map(\.hit.notification), now: now, lastFired: lastFired,
                               quietHours: quiet, calendar: calendar)
        // Both ledgers are written before the (app-side) first `await`.
        for n in fire { lastFired[n] = now }
        watermark.merge(LiveHealthAlerts.watermarks(fired: fire, from: live)) { max($0, $1) }

        let posted = live.map(\.hit).filter { fire.contains($0.notification) }
        delivered += posted
        return posted
    }
}
