// AES-128-ECB against NIST known-answer vectors, and CRC-32 against its standard check value and
// the spec's own worked examples.

import XCTest
@testable import ZeppKit

final class AESAndCRCTests: XCTestCase {

    /// FIPS-197 Appendix C.1 (AES-128).
    func testFIPS197AppendixC1() throws {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let plain = hex("00112233445566778899aabbccddeeff")
        let cipher = hex("69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(try ZeppAES.encryptECB(key: key, plain), cipher)
        XCTAssertEqual(try ZeppAES.decryptECB(key: key, cipher), plain)
    }

    /// FIPS-197 Appendix B (the cipher example).
    func testFIPS197AppendixB() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        XCTAssertEqual(try ZeppAES.encryptECB(key: key, hex("3243f6a8885a308d313198a2e0370734")),
                       hex("3925841d02dc09fbdc118597196a0b32"))
    }

    /// NIST SP 800-38A F.1.1 / F.1.2: ECB-AES128, four blocks, each encrypted independently.
    func testSP80038AECBAES128() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a" + "ae2d8a571e03ac9c9eb76fac45af8e51"
                        + "30c81c46a35ce411e5fbc1191a0a52ef" + "f69f2445df4f9b17ad2b417be66c3710")
        let cipher = hex("3ad77bb40d7a3660a89ecaf32466ef97" + "f5d3d58503b9699de785895a96fdbaaf"
                         + "43b1cd7f598ece23881b00e3ed030688" + "7b0c785e27e8ad3f8223207104725dd4")
        XCTAssertEqual(try ZeppAES.encryptECB(key: key, plain), cipher)
        XCTAssertEqual(try ZeppAES.decryptECB(key: key, cipher), plain)
        // ECB: block 3 alone encrypts to ciphertext block 3.
        XCTAssertEqual(try ZeppAES.encryptECB(key: key, Array(plain[32..<48])), Array(cipher[32..<48]))
    }

    func testRejectsBadKeyAndUnalignedInput() {
        XCTAssertThrowsError(try ZeppAES.encryptECB(key: [UInt8](repeating: 0, count: 15), [UInt8](repeating: 0, count: 16))) {
            XCTAssertEqual($0 as? ZeppAES.Error, .invalidKeyLength)
        }
        XCTAssertThrowsError(try ZeppAES.encryptECB(key: [UInt8](repeating: 0, count: 32), [UInt8](repeating: 0, count: 16)))
        XCTAssertThrowsError(try ZeppAES.decryptECB(key: [UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 17))) {
            XCTAssertEqual($0 as? ZeppAES.Error, .notBlockAligned)
        }
        XCTAssertEqual(try ZeppAES.encryptECB(key: [UInt8](repeating: 0, count: 16), []), [])
    }

    func testCRC32CheckValue() {
        XCTAssertEqual(ZeppCRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZeppCRC32.checksum([UInt8]()), 0)
    }

    /// §3.7 (CRC over P ‖ S) and §6.2 worked example D (CRC over the fetched data).
    func testCRC32SpecExamples() {
        XCTAssertEqual(ZeppCRC32.checksum(hex("01 01 ea 07 09 1e 0c 00 00 08 31 d2 33 29")), 0x9530_d05f)
        XCTAssertEqual(ZeppCRC32.checksum(hex("8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39")), 0xd7bb_6239)
    }
}
