// Endpoint numbers of the chunked protocol and which of them are encrypted
// (ZEPP_PROTOCOL.md §3.5, overridden per device by the services list, §5.2).

import Foundation

public enum ZeppEndpoint {
    public static let servicesList: UInt16 = 0x0000
    public static let config: UInt16 = 0x000A
    public static let connection: UInt16 = 0x0015
    public static let realtimeSteps: UInt16 = 0x0016
    public static let userInfo: UInt16 = 0x0017
    public static let heartRate: UInt16 = 0x001D
    public static let battery: UInt16 = 0x0029
    public static let deviceInfo: UInt16 = 0x0043
    public static let time: UInt16 = 0x0047
    public static let activityFetch: UInt16 = 0x004B
    public static let authentication: UInt16 = 0x0082

    /// "Default encrypted (before the services list overrides)", §3.5.
    public static let defaultEncryption: [UInt16: Bool] = [
        servicesList: false,
        config: true,
        connection: true,
        realtimeSteps: false,
        userInfo: true,
        heartRate: false,
        battery: true,
        deviceInfo: false,
        time: false,
        activityFetch: true,
        authentication: false,
    ]
}

/// The endpoint table a device returns for a services-list request (§5.2).
public struct ZeppServicesList: Equatable {
    public struct Entry: Equatable {
        public let endpoint: UInt16
        /// `true`/`false` for flag `01`/`00`; nil for any other flag value ("leave the default").
        public let encrypted: Bool?
    }

    public let entries: [Entry]

    public func contains(_ endpoint: UInt16) -> Bool {
        entries.contains { $0.endpoint == endpoint }
    }

    /// Request payload: `03`.
    public static let request: [UInt8] = [0x03]

    /// Reply: `04`, u16 count, then count × (u16 endpoint, u8 flag). nil when malformed or truncated.
    public static func parse(_ payload: [UInt8]) -> ZeppServicesList? {
        var reader = ZeppByteReader(payload)
        guard reader.u8() == 0x04, let count = reader.u16() else { return nil }
        var entries = [Entry]()
        for _ in 0..<Int(count) {
            guard let endpoint = reader.u16(), let flag = reader.u8() else { return nil }
            let encrypted: Bool?
            switch flag {
            case 0x00: encrypted = false
            case 0x01: encrypted = true
            default: encrypted = nil
            }
            entries.append(Entry(endpoint: endpoint, encrypted: encrypted))
        }
        return ZeppServicesList(entries: entries)
    }
}

/// Which endpoints a phone must encrypt: the §3.5 defaults, overridden by the services list.
public struct ZeppEndpointEncryption: Equatable {
    private var overrides: [UInt16: Bool] = [:]

    public init() {}

    public mutating func apply(_ list: ZeppServicesList) {
        for entry in list.entries {
            if let encrypted = entry.encrypted { overrides[entry.endpoint] = encrypted }
        }
    }

    public func isEncrypted(_ endpoint: UInt16) -> Bool {
        // The auth endpoint is always plaintext, whatever a services list says (§3.3).
        if endpoint == ZeppEndpoint.authentication { return false }
        if let override = overrides[endpoint] { return override }
        // SPEC-GAP: the spec gives no default for endpoints missing from §3.5. Treat them as
        // plaintext until a services list says otherwise; ZeppKit only sends to listed endpoints.
        return ZeppEndpoint.defaultEncryption[endpoint] ?? false
    }
}
