import Foundation
import OpenCircuitKit

// `RingSession` as a `WearableSession` (#214). Deliberately thin: the connection, battery, live-HR
// and sync requirements are satisfied by members `RingSession` already has under the same names.
// Only the three device-description properties are new, and each is derived from `firmwareInfo`
// (observed), so SwiftUI re-renders when the DIS reads land.
extension RingSession: WearableSession {
    var deviceKind: WearableDeviceKind { .ringConn(model: firmwareInfo.generation) }

    var capabilities: WearableCapabilities { .ringConn(generation: firmwareInfo.generation) }

    /// The advertised name ends in two MAC bytes ("RingConn Gen2-03AD"), so it goes through
    /// `RingMetadataStore.modelFamily` — the same strip the export applies — before it can reach
    /// Apple Health. `firmwareInfo.mac` is never read.
    var identity: WearableIdentity {
        .ringConn(id: peripheralIdentifier,
                  modelFamily: RingMetadataStore.modelFamily(firmwareInfo.modelName),
                  firmware: firmwareInfo)
    }
}
