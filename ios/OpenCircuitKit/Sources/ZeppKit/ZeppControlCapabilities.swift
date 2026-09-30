// Which device controls the connected strap supports (ZEPP_PROTOCOL.md §14).
//
// Rule: a control is supported only when the strap has POSITIVELY reported it in this connection.
// Absent, unknown or malformed means unsupported, and an unsupported control sends nothing. This
// gate is the connection-level half: device model, completed auth and the services list (§5.2).
// The per-feature machines add what they learn themselves: `ZeppFindDevice` the continuous/one-shot
// version (§11.2), `ZeppAlarmEditor` the alarm list and the time set (§14 "Alarms" rows),
// `ZeppHapticAlertSettings` the config capabilities and read reply (§13.4).

import Foundation

/// The device controls of §11–§13.
public enum ZeppControl: String, CaseIterable, Equatable {
    /// Start/stop "find device" (§11).
    case findDevice
    /// A short buzz: find-device start, then stop 500 ms later (§13.2).
    case buzz
    /// Answering the strap's "find phone" request (§11.5).
    case findPhone
    /// Reading the alarm list. Viewing and editing need more, see `ZeppAlarmEditor` (§14).
    case alarms
    /// Vibration patterns (§13.1): never exposed in v1, whatever the services list says (§14).
    case vibrationPatterns
    /// Strap-side haptic alert settings on the config endpoint (§13.4). Each setting is further
    /// gated by `ZeppHapticAlertSettings`.
    case hapticAlerts

    /// The endpoint the control talks to.
    public var endpoint: UInt16 {
        switch self {
        case .findDevice, .buzz, .findPhone: return ZeppEndpoint.findDevice
        case .alarms: return ZeppEndpoint.alarms
        case .vibrationPatterns: return ZeppEndpoint.vibrationPatterns
        case .hapticAlerts: return ZeppEndpoint.config
        }
    }
}

public enum ZeppControlUnsupportedReason: Equatable {
    /// §14 device gate: §11–§15 apply to the Helio Strap only. The Helio Ring shares the protocol
    /// but is routed differently and stays out of scope until tested.
    case notHelioStrap
    /// No completed auth (`10 05 01`) on this connection (§11.6).
    case notAuthenticated
    /// No services list received on this connection (§5.2).
    case noServicesList
    /// The services list does not contain the control's endpoint.
    case endpointNotListed(UInt16)
    /// §14: vibration patterns are not exposed in v1 (no read-back, §15.1).
    case notInV1
}

public enum ZeppControlSupport: Equatable {
    case supported
    case unsupported(ZeppControlUnsupportedReason)

    public var isSupported: Bool { self == .supported }
}

/// Thrown by every control machine instead of sending to an unsupported control.
public enum ZeppControlError: Error, Equatable {
    case unsupported(ZeppControl, ZeppControlUnsupportedReason)
}

/// The connection-level capability gate. Build a new one for every connection, after auth and the
/// services list; `.disconnected` supports nothing.
public struct ZeppControlCapabilities: Equatable {
    public let model: ZeppDeviceModel?
    public let isAuthenticated: Bool
    public let services: ZeppServicesList?

    public init(model: ZeppDeviceModel?, isAuthenticated: Bool, services: ZeppServicesList?) {
        self.model = model
        self.isAuthenticated = isAuthenticated
        self.services = services
    }

    /// Nothing connected: every control is unsupported.
    public static let disconnected = ZeppControlCapabilities(model: nil, isAuthenticated: false, services: nil)

    public func support(_ control: ZeppControl) -> ZeppControlSupport {
        guard model == .helioStrap else { return .unsupported(.notHelioStrap) }
        guard isAuthenticated else { return .unsupported(.notAuthenticated) }
        guard let services else { return .unsupported(.noServicesList) }
        if control == .vibrationPatterns { return .unsupported(.notInV1) }
        guard services.contains(control.endpoint) else { return .unsupported(.endpointNotListed(control.endpoint)) }
        return .supported
    }

    public func isSupported(_ control: ZeppControl) -> Bool {
        support(control).isSupported
    }

    /// Throws `ZeppControlError.unsupported` unless the control is supported.
    public func require(_ control: ZeppControl) throws {
        if case .unsupported(let reason) = support(control) {
            throw ZeppControlError.unsupported(control, reason)
        }
    }
}
