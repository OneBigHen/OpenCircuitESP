// Device info (§5.3): hardware and firmware versions only, the serial number and PnP ID never
// kept, and no guess at the bit-0 blob's prefix width that the reply can't back up. Then the
// HelioVerify `--trace` lines, which must never carry a data payload. All values are made up.

import XCTest
@testable import ZeppKit

final class DeviceInfoAndTraceTests: XCTestCase {

    private let serial = Array("FAKE0001".utf8) + [0]
    private let hardware = Array("0.99.1.0".utf8) + [0]
    private let firmware = Array("9.9.9.9".utf8) + [0]
    private let pnp = hex("01 02 03 04 05 06 07")

    private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    private func reply(flags: UInt64, blob: [UInt8] = []) -> [UInt8] {
        var out: [UInt8] = [0x02, 0x01] + le64(flags) + blob
        out += serial
        out += hardware
        out += firmware
        if flags & 0x10 != 0 { out += pnp }
        return out
    }

    private func assertKeepsNoIdentifier(_ info: ZeppDeviceInfo?, file: StaticString = #filePath, line: UInt = #line) {
        let dump = String(reflecting: info)
        XCTAssertFalse(dump.contains("FAKE0001"), dump, file: file, line: line)
        XCTAssertFalse(dump.contains("[1, 2, 3, 4, 5, 6, 7]"), dump, file: file, line: line)
    }

    // MARK: Layouts

    func testWithoutBlob() throws {
        let info = try XCTUnwrap(ZeppDeviceInfo.parse(reply(flags: 0x1e)))
        XCTAssertEqual(info.hardwareVersion, "0.99.1.0")
        XCTAssertEqual(info.firmwareVersion, "9.9.9.9")
        XCTAssertEqual(info.blobPrefixWidths, [0])
        XCTAssertFalse(info.isAmbiguous)
        assertKeepsNoIdentifier(info)
    }

    func testBlobWithEachPrefixWidth() throws {
        // u8, u16 and u32 prefixes around the same non-printable 3-byte blob: only the right width parses.
        for (prefix, width) in [(hex("03"), 1), (hex("03 00"), 2), (hex("03 00 00 00"), 4)] {
            let info = try XCTUnwrap(ZeppDeviceInfo.parse(reply(flags: 0x1f, blob: prefix + hex("aa bb cc"))))
            XCTAssertEqual(info.blobPrefixWidths, [width])
            XCTAssertEqual(info.hardwareVersion, "0.99.1.0")
            XCTAssertEqual(info.firmwareVersion, "9.9.9.9")
            assertKeepsNoIdentifier(info)
        }
    }

    func testWidthsThatAgreeAreReported() throws {
        // A u16 prefix whose blob ends in a printable byte: read as u8, the shift is absorbed by the
        // serial number, so both widths parse and locate the same versions.
        let info = try XCTUnwrap(ZeppDeviceInfo.parse(reply(flags: 0x1f, blob: hex("03 00 41 42 43"))))
        XCTAssertEqual(info.blobPrefixWidths, [1, 2])
        XCTAssertFalse(info.isAmbiguous)
        XCTAssertEqual(info.firmwareVersion, "9.9.9.9")
        assertKeepsNoIdentifier(info)
    }

    func testWidthsThatDisagreeReportNothing() throws {
        // A u16 prefix whose blob ends in 00: read as u8, the serial number would land in the
        // hardware field. Both widths parse, they disagree, so no version is reported.
        let info = try XCTUnwrap(ZeppDeviceInfo.parse(reply(flags: 0x1f, blob: hex("03 00 41 42 00"))))
        XCTAssertEqual(info.blobPrefixWidths, [1, 2])
        XCTAssertTrue(info.isAmbiguous)
        XCTAssertNil(info.hardwareVersion)
        XCTAssertNil(info.firmwareVersion)
        assertKeepsNoIdentifier(info)
    }

    func testFlagsWithoutVersionFields() throws {
        let info = try XCTUnwrap(ZeppDeviceInfo.parse([0x02, 0x01] + le64(0x02) + serial))
        XCTAssertNil(info.hardwareVersion)
        XCTAssertNil(info.firmwareVersion)
        assertKeepsNoIdentifier(info)
    }

    // MARK: Truncation and garbage

    func testEveryTruncationIsRejected() {
        for full in [reply(flags: 0x1e), reply(flags: 0x1f, blob: hex("03 aa bb cc"))] {
            XCTAssertNotNil(ZeppDeviceInfo.parse(full))
            for length in 0..<full.count {
                XCTAssertNil(ZeppDeviceInfo.parse(Array(full.prefix(length))), "truncated to \(length)")
            }
        }
    }

    func testWrongHeaderOrBadStringsAreRejected() {
        var wrongStatus = reply(flags: 0x1e)
        wrongStatus[1] = 0x00
        var wrongOpcode = reply(flags: 0x1e)
        wrongOpcode[0] = 0x04
        let invalidUTF8: [UInt8] = [0x02, 0x01] + le64(0x0c) + [0xc3, 0x28, 0x00] + firmware
        let controlCharacter: [UInt8] = [0x02, 0x01] + le64(0x0c) + hardware + [0x39, 0x07, 0x00]
        let blobPastTheEnd: [UInt8] = [0x02, 0x01] + le64(0x1d) + [0xff, 0x01, 0x02]
        for bad in [wrongStatus, wrongOpcode, invalidUTF8, controlCharacter, blobPastTheEnd, hex("02 01")] {
            XCTAssertNil(ZeppDeviceInfo.parse(bad), ZeppHex.string(bad))
        }
    }

    func testRandomRepliesNeverTrapAndOnlyYieldPrintableVersions() {
        var gen = TestBytes(seed: 43)
        for _ in 0..<2000 {
            var bytes = gen.bytes(gen.int(0...48))
            if bytes.count >= 2, gen.int(0...3) > 0 { bytes[0] = 0x02; bytes[1] = 0x01 }
            if bytes.count >= 10, gen.int(0...1) == 0 {
                for i in 3..<10 { bytes[i] = 0 }                // plausible small flags
                bytes[2] &= 0x1f
            }
            guard let info = ZeppDeviceInfo.parse(bytes) else { continue }
            for version in [info.hardwareVersion, info.firmwareVersion].compactMap({ $0 }) {
                XCTAssertTrue(version.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
            }
            XCTAssertFalse(info.blobPrefixWidths.isEmpty)
        }
    }

    // MARK: --trace lines

    func testTraceControlLinesAreHex() {
        XCTAssertEqual(ZeppFetchTrace.control(hex("01 01 ea 07 09 1e 0b 37 00 f0"), outgoing: true),
                       "→ …0004 01 01 ea 07 09 1e 0b 37 00 f0")
        XCTAssertEqual(ZeppFetchTrace.control(hex("10 03 01"), outgoing: false), "← …0004 10 03 01")
        XCTAssertEqual(ZeppFetchTrace.control(hex("10 03 01"), outgoing: false, channel: "0x004b"), "← 0x004b 10 03 01")
        XCTAssertEqual(ZeppFetchTrace.control([], outgoing: false), "← …0004 (empty)")
    }

    func testTraceDataLinesNeverCarryThePayload() {
        let packet: [UInt8] = [0x05] + [UInt8](repeating: 0xab, count: 240)
        let line = ZeppFetchTrace.dataPacket(packet)
        XCTAssertEqual(line, "← …0005 241 B, counter 05")
        XCTAssertFalse(line.contains("ab"))
        XCTAssertEqual(ZeppFetchTrace.dataPacket([]), "← …0005 0 B (empty)")
    }
}
