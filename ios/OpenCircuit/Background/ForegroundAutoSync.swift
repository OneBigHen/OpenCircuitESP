import Foundation

/// The foreground auto-sync throttle, one constant for both devices: the ring's
/// `ContentView.maybeAutoSyncOnReady` and the strap's activation sync (`HelioActivationSync`,
/// review-225e SF-1) both skip a sync when the last one is younger than this.
enum ForegroundAutoSync {
    /// Raised 120→300 s: a FLAKY ring reconnects/relaunches repeatedly and each one re-fired the
    /// auto-sync, so a ~2-min spacing let almost every reconnect run a full ~30 s (usually empty) sync
    /// that blocks the workout Start. The periodic/BLE-wake drain still delivers the backlog on its own
    /// cadence; this only suppresses the redundant reconnect re-sync. (Kept at 300 s, NOT 600 s — the
    /// throttle also honours the PERSISTED `lastSuccessfulSync`, which a *partial* background drain
    /// bumps (epochs>0 yet the night not fully drained); a longer window would suppress the foreground
    /// continuation drain of the night's tail for that whole window. 300 s bounds that delay, and the
    /// hourly wake-drain backstops the tail regardless — review MEDIUM.)
    static let interval: TimeInterval = 300
}
