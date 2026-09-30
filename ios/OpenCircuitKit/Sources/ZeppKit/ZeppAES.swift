// AES-128 in ECB mode without padding, through CommonCrypto. The Zepp protocol uses it for the
// auth proof (§4.3) and for every encrypted chunked message (§3.3): each 16-byte block is
// encrypted independently with no IV.

import CommonCrypto
import Foundation

public enum ZeppAES {

    public static let blockLength = 16
    public static let keyLength = 16

    public enum Error: Swift.Error, Equatable {
        case invalidKeyLength
        /// ECB without padding needs a whole number of 16-byte blocks.
        case notBlockAligned
        case cryptorFailed(status: Int32)
    }

    public static func encryptECB(key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        try crypt(CCOperation(kCCEncrypt), key: key, data)
    }

    public static func decryptECB(key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        try crypt(CCOperation(kCCDecrypt), key: key, data)
    }

    private static func crypt(_ operation: CCOperation, key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else { throw Error.invalidKeyLength }
        guard data.count % blockLength == 0 else { throw Error.notBlockAligned }
        if data.isEmpty { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(operation,
                             CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode),
                             key, key.count,
                             nil,
                             data, data.count,
                             &out, out.count,
                             &moved)
        guard status == CCCryptorStatus(kCCSuccess), moved == data.count else {
            throw Error.cryptorFailed(status: status)
        }
        return out
    }
}
