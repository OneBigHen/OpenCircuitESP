import Foundation

/// Whether the ring reverse-engineering readout (the "Ring Debug" section at the bottom of
/// Background Activity: last sync summary and last raw frame) is shown. The activity-channel probe
/// next to it writes to the ring, so it is compiled into DEBUG builds only and this gate does not
/// cover it.
///
/// App Store readiness: a store build must not greet every user, or App Review, with raw hex frames.
/// A compile-time `#if DEBUG` gate would also take the readout from TestFlight testers, and a runtime
/// "is this TestFlight?" check can't work because App Review runs the build with the same sandbox
/// receipt TestFlight does. So: always on in DEBUG, and in Release off until unlocked by tapping the
/// version line in Profile's footer `unlockTapCount` times (the same taps lock it again). Unlocking
/// reveals a read-only readout; it changes no sync, storage or Health behaviour.
enum DeveloperTools {
    static let unlockedKey = "developerTools.unlocked"
    static let unlockTapCount = 7

    static func isVisible(unlocked: Bool) -> Bool {
        #if DEBUG
        return true
        #else
        return unlocked
        #endif
    }
}
