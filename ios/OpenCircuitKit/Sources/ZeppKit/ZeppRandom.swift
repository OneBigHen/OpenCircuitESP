// Injectable randomness for key generation (ZEPP_PROTOCOL.md §4.2). Production uses the system
// CSPRNG; tests inject fixed bytes so the handshake is reproducible.

import Foundation
import Security

public struct ZeppRandom {

    public enum Error: Swift.Error, Equatable {
        case systemRandomFailed(status: Int32)
        case exhausted
    }

    private let draw: (Int) throws -> [UInt8]

    public init(_ draw: @escaping (Int) throws -> [UInt8]) {
        self.draw = draw
    }

    public func bytes(_ count: Int) throws -> [UInt8] {
        let out = try draw(count)
        guard out.count == count else { throw Error.exhausted }
        return out
    }

    /// `SecRandomCopyBytes`, as the spec requires (never a non-cryptographic generator).
    public static let system = ZeppRandom { count in
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        guard status == errSecSuccess else { throw Error.systemRandomFailed(status: status) }
        return out
    }

    /// Hands out `stream` in order and throws once it runs out. For tests and fixtures only, so it is
    /// internal: tests reach it through `@testable import`, and no app or tool can pick it by mistake.
    static func fixed(_ stream: [UInt8]) -> ZeppRandom {
        let box = FixedStream(stream)
        return ZeppRandom { count in try box.take(count) }
    }

    private final class FixedStream {
        private var remaining: ArraySlice<UInt8>
        init(_ bytes: [UInt8]) { remaining = bytes[...] }
        func take(_ count: Int) throws -> [UInt8] {
            guard remaining.count >= count else { throw Error.exhausted }
            let out = Array(remaining.prefix(count))
            remaining = remaining.dropFirst(count)
            return out
        }
    }
}
