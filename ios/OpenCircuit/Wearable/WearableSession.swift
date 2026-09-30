import Foundation
import Observation
import OpenCircuitKit

/// "Any wearable" — the seam in front of `RingSession` (#214, docs/DEVICE_SEAM.md).
///
/// The members are the device-agnostic surface the app already reads: connection, battery, live
/// HR, a history sync. They deliberately keep `RingSession`'s existing names (`ready`, `syncing`,
/// `batteryPercent`, …) so a view retyped from `RingSession?` to `(any WearableSession)?` changes
/// only its type, not its call sites.
///
/// Everything else `RingSession` exposes is the RingConn protocol surfacing in UI, and stays on the
/// concrete type. Device-specific controls gate on `capabilities`.
@MainActor
protocol WearableSession: AnyObject, Observable {
    /// Which device family and model this session drives.
    var deviceKind: WearableDeviceKind { get }
    /// Who the device is — the source of the `HKDevice` on every Health write.
    var identity: WearableIdentity { get }
    /// What the device can do right now. May grow as the device identifies itself.
    var capabilities: WearableCapabilities { get }

    // Connection
    /// The link is up and the device is answering commands.
    var ready: Bool { get }
    /// CoreBluetooth holds the link (it can be up before `ready`).
    var isLinkConnected: Bool { get }
    /// When the device last sent anything.
    var lastFrameAt: Date? { get }

    // Battery
    var batteryPercent: Int? { get }
    var charging: Bool { get }

    // Live readings
    var liveHR: Int? { get }
    var liveHRAt: Date? { get }
    /// The device's own step count for today, when it keeps one.
    var steps: Int? { get }

    // History
    var syncing: Bool { get }
    var syncStatus: String? { get }
    /// Pull the device's stored history into the local store (and on to Apple Health).
    func syncHistory(manual: Bool)
}
