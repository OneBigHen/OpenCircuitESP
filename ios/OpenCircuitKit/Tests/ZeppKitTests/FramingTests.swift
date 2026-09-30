// Chunked framing and message encryption (§3): the spec's worked examples byte for byte, then
// round-trips and the reassembler's strictness.

import XCTest
@testable import ZeppKit

final class FramingTests: XCTestCase {

    private var publicKeyMessage: [UInt8] { [0x04, 0x02, 0x00, 0x02] + SpecC.phonePubX + SpecC.phonePubY }

    // MARK: Worked example A (§3.6)

    func testWorkedExampleAPlaintextAtMTU23() throws {
        let chunks = try ZeppChunkCodec.chunks(body: publicKeyMessage, declaredLength: 52, endpoint: 0x0082,
                                               handle: 0x01, encrypted: false, maxWriteLength: 20)
        XCTAssertEqual(chunks, [
            hex("03 01 00 01 00 34 00 00 00 82 00 04 02 00 02 a1 e4 ad 02 c2"),
            hex("03 00 00 01 01 a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c"),
            hex("03 00 00 01 02 07 00 00 00 cd 50 73 a0 6d 67 b7 8a 3b c5 f5"),
            hex("03 06 00 01 03 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00"),
        ])
    }

    func testWorkedExampleAAtMTU247IsOneChunk() throws {
        let chunks = try ZeppChunkCodec.chunks(body: publicKeyMessage, declaredLength: 52, endpoint: 0x0082,
                                               handle: 0x01, encrypted: false, maxWriteLength: 244)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 63)
        XCTAssertEqual(Array(chunks[0].prefix(11)), hex("03 07 00 01 00 34 00 00 00 82 00"))
        XCTAssertEqual(Array(chunks[0].dropFirst(11)), publicKeyMessage)
    }

    // MARK: Worked example B (§3.7)

    private let exampleBPayload = hex("01 01 ea 07 09 1e 0c 00 00 08")
    private let exampleBCiphertext = hex("f9 54 ea 42 20 6c b5 96 23 e5 3d c0 11 39 f3 ea e7 6b 3a b5 34 16 39 ae d3 4b de 6d 1c 3b 34 37")

    func testWorkedExampleBEncryption() throws {
        var crypto = try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: 0x2933_d231)
        XCTAssertEqual(crypto.messageKey(handle: 0x03), hex("8f 46 6d 05 20 91 2c a8 70 cd 02 a3 ce de ed fc"))
        let sealed = try crypto.seal(exampleBPayload, handle: 0x03)
        XCTAssertEqual(sealed, exampleBCiphertext)
        XCTAssertEqual(crypto.nextSequence, 0x2933_d232)

        let opened = try crypto.open(sealed, handle: 0x03, plaintextLength: 10)
        XCTAssertEqual(opened.payload, exampleBPayload)
        XCTAssertEqual(opened.trailerCRCMatches, true)
        XCTAssertEqual(opened.trailerSequence, 0x2933_d231)
    }

    func testWorkedExampleBChunksAtMTU23And247() throws {
        XCTAssertEqual(try ZeppChunkCodec.chunks(body: exampleBCiphertext, declaredLength: 10, endpoint: 0x004B,
                                                 handle: 0x03, encrypted: true, maxWriteLength: 20), [
            hex("03 09 00 03 00 0a 00 00 00 4b 00 f9 54 ea 42 20 6c b5 96 23"),
            hex("03 08 00 03 01 e5 3d c0 11 39 f3 ea e7 6b 3a b5 34 16 39 ae"),
            hex("03 0e 00 03 02 d3 4b de 6d 1c 3b 34 37"),
        ])
        let one = try ZeppChunkCodec.chunks(body: exampleBCiphertext, declaredLength: 10, endpoint: 0x004B,
                                            handle: 0x03, encrypted: true, maxWriteLength: 244)
        XCTAssertEqual(one, [hex("03 0f 00 03 00 0a 00 00 00 4b 00") + exampleBCiphertext])
    }

    /// The transport produces example B end to end: third message → handle 3, encrypted endpoint.
    func testTransportProducesWorkedExampleBAsThirdMessage() throws {
        var transport = ZeppChunkedTransport(maxWriteLength: 20)
        _ = try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00])   // handle 1
        _ = try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [0x00])   // handle 2
        transport.install(session: try ZeppSessionCrypto(sessionKey: SpecC.sessionKey, sequenceSeed: 0x2933_d231))
        let chunks = try transport.encode(endpoint: ZeppEndpoint.activityFetch, payload: exampleBPayload)
        XCTAssertEqual(chunks.map { $0[3] }, [3, 3, 3])
        XCTAssertEqual(chunks[0], hex("03 09 00 03 00 0a 00 00 00 4b 00 f9 54 ea 42 20 6c b5 96 23"))
        XCTAssertEqual(chunks[2], hex("03 0e 00 03 02 d3 4b de 6d 1c 3b 34 37"))
        XCTAssertEqual(transport.session?.nextSequence, 0x2933_d232)
    }

    // MARK: Transport state

    func testHandlesStartAtOneAndWrap() throws {
        var transport = ZeppChunkedTransport(maxWriteLength: 244)
        var handles = [UInt8]()
        for _ in 0..<257 {
            handles.append(try transport.encode(endpoint: ZeppEndpoint.servicesList, payload: [0x03])[0][3])
        }
        XCTAssertEqual(handles.first, 0x01)
        XCTAssertEqual(handles[254], 0xFF)
        XCTAssertEqual(handles[255], 0x00)
        XCTAssertEqual(handles[256], 0x01)
        transport.reset()
        XCTAssertEqual(try transport.encode(endpoint: ZeppEndpoint.servicesList, payload: [0x03])[0][3], 0x01)
    }

    func testEncryptedEndpointNeedsASessionAndConsumesNoHandle() throws {
        var transport = ZeppChunkedTransport(maxWriteLength: 244)
        XCTAssertThrowsError(try transport.encode(endpoint: ZeppEndpoint.battery, payload: [0x03])) {
            XCTAssertEqual($0 as? ZeppChunkedTransport.Error, .notAuthenticated(endpoint: ZeppEndpoint.battery))
        }
        XCTAssertEqual(transport.lastHandle, 0)
        // The auth endpoint is plaintext even if a services list claims otherwise.
        transport.apply(servicesList: ZeppServicesList(entries: [.init(endpoint: ZeppEndpoint.authentication, encrypted: true)]))
        XCTAssertFalse(transport.isEncrypted(endpoint: ZeppEndpoint.authentication))
        XCTAssertEqual(try transport.encode(endpoint: ZeppEndpoint.authentication, payload: [1])[0][1], 0x07)
    }

    func testWriteLengthTooSmallIsAnError() {
        XCTAssertThrowsError(try ZeppChunkCodec.chunks(body: [1], declaredLength: 1, endpoint: 0, handle: 1,
                                                       encrypted: false, maxWriteLength: 11))
        XCTAssertNoThrow(try ZeppChunkCodec.chunks(body: [1], declaredLength: 1, endpoint: 0, handle: 1,
                                                   encrypted: false, maxWriteLength: 12))
    }

    func testWriteLengthIsCappedAt512() throws {
        let body = [UInt8](repeating: 0xAB, count: 1200)
        let chunks = try ZeppChunkCodec.chunks(body: body, declaredLength: body.count, endpoint: 0x16, handle: 1,
                                               encrypted: false, maxWriteLength: 4096)
        XCTAssertEqual(chunks.map(\.count).max(), 512)
    }

    func testPaddedCiphertextLength() {
        XCTAssertEqual(ZeppChunkCodec.paddedCiphertextLength(plaintextLength: 0), 16)
        XCTAssertEqual(ZeppChunkCodec.paddedCiphertextLength(plaintextLength: 8), 16)
        XCTAssertEqual(ZeppChunkCodec.paddedCiphertextLength(plaintextLength: 9), 32)
        XCTAssertEqual(ZeppChunkCodec.paddedCiphertextLength(plaintextLength: 10), 32)
    }

    // MARK: Round trips (phone framing fed back through the device → phone reassembler)

    func testPlaintextRoundTripsAcrossSizesAndWriteLengths() throws {
        var gen = TestBytes(seed: 7)
        for writeLength in [12, 20, 23, 100, 244, 512] {
            for size in [0, 1, 8, 9, 10, 23, 24, 52, 255, 256, 700] {
                let payload = gen.bytes(size)
                let chunks = try ZeppChunkCodec.chunks(body: payload, declaredLength: size, endpoint: 0x0029,
                                                       handle: 0x42, encrypted: false, maxWriteLength: writeLength)
                XCTAssertTrue(chunks.allSatisfy { $0.count <= min(writeLength, 512) })
                var reassembler = ZeppChunkReassembler()
                var events = [ZeppChunkReassembler.Event]()
                for chunk in chunks { events += reassembler.accept(chunk) }
                guard events.count == 1, case .message(let m) = events[0] else {
                    return XCTFail("size \(size) @ \(writeLength): \(events)")
                }
                XCTAssertEqual(m.body, payload)
                XCTAssertEqual(m.endpoint, 0x0029)
                XCTAssertEqual(m.handle, 0x42)
                XCTAssertEqual(Int(m.lastChunkIndex), chunks.count - 1)
                XCTAssertTrue(m.ackRequested)
            }
        }
    }

    func testEncryptedRoundTripThroughTheTransport() throws {
        var gen = TestBytes(seed: 11)
        let session = try ZeppSessionCrypto(sessionKey: gen.bytes(16), sequenceSeed: 77)
        var transport = ZeppChunkedTransport(maxWriteLength: 20)
        transport.install(session: session)
        var deviceSide = session
        for (i, size) in [0, 1, 7, 8, 9, 16, 40, 300].enumerated() {
            let payload = gen.bytes(size)
            let handle = UInt8(i + 1)
            let body = try deviceSide.seal(payload, handle: handle)
            let chunks = try ZeppChunkCodec.chunks(body: body, declaredLength: size, endpoint: 0x0029,
                                                   handle: handle, encrypted: true, maxWriteLength: 20)
            var received = ZeppChunkedTransport.Received()
            for chunk in chunks {
                let r = transport.receive(chunk)
                received.events += r.events
                received.acks += r.acks
            }
            XCTAssertEqual(received.events, [.message(ZeppMessage(endpoint: 0x0029, payload: payload, handle: handle,
                                                                   wasEncrypted: true, trailerCRCMatches: true))])
            XCTAssertEqual(received.acks, [ZeppChunkCodec.chunkAck(handle: handle, count: UInt8(chunks.count - 1))])
        }
    }

    func testEncryptedMessageWithoutSessionIsUndecryptableAndNotAcked() throws {
        var sender = try ZeppSessionCrypto(sessionKey: [UInt8](repeating: 1, count: 16), sequenceSeed: 0)
        let body = try sender.seal([1, 2, 3], handle: 5)
        let chunks = try ZeppChunkCodec.chunks(body: body, declaredLength: 3, endpoint: 0x0029, handle: 5,
                                               encrypted: true, maxWriteLength: 244)
        var transport = ZeppChunkedTransport()
        let r = transport.receive(chunks[0])
        XCTAssertEqual(r.events, [.undecryptable(endpoint: 0x0029, handle: 5)])
        XCTAssertEqual(r.acks, [])
    }

    func testChunkAckBytes() {
        XCTAssertEqual(ZeppChunkCodec.chunkAck(handle: 0x07, count: 0x02), hex("04 00 07 01 02"))
    }

    // MARK: Reassembler strictness

    private func chunks(_ size: Int, handle: UInt8 = 9, writeLength: Int = 20) -> [[UInt8]] {
        try! ZeppChunkCodec.chunks(body: [UInt8](repeating: 0x5A, count: size), declaredLength: size,
                                   endpoint: 0x0043, handle: handle, encrypted: false, maxWriteLength: writeLength)
    }

    func testChunkIndexGapDiscardsTheMessage() {
        let c = chunks(40)          // 9 + 15 + 15 + 1 → 4 chunks
        var r = ZeppChunkReassembler()
        XCTAssertEqual(r.accept(c[0]), [])
        XCTAssertEqual(r.accept(c[2]), [.dropped(.chunkIndexGap(expected: 1, got: 2))])
        XCTAssertFalse(r.hasMessageInProgress)
        XCTAssertEqual(r.accept(c[3]), [.dropped(.orphanContinuation)])
    }

    func testRepeatedChunkIsAGap() {
        let c = chunks(40)
        var r = ZeppChunkReassembler()
        _ = r.accept(c[0]); _ = r.accept(c[1])
        XCTAssertEqual(r.accept(c[1]), [.dropped(.chunkIndexGap(expected: 2, got: 1))])
    }

    func testForeignHandleChunkIsIgnoredAndTheMessageContinues() {
        let c = chunks(40, handle: 9)
        let other = chunks(40, handle: 10)
        var r = ZeppChunkReassembler()
        _ = r.accept(c[0])
        XCTAssertEqual(r.accept(other[1]), [.dropped(.foreignHandle(expected: 9, got: 10))])
        _ = r.accept(c[1]); _ = r.accept(c[2])
        guard case .message(let m)? = r.accept(c[3]).first else { return XCTFail() }
        XCTAssertEqual(m.body.count, 40)
    }

    func testNewFirstChunkSupersedesAnIncompleteMessage() {
        let a = chunks(40, handle: 1)
        let b = chunks(5, handle: 2)
        var r = ZeppChunkReassembler()
        _ = r.accept(a[0])
        let events = r.accept(b[0])
        XCTAssertEqual(events.first, .dropped(.supersededByNewMessage(handle: 1)))
        guard case .message(let m)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(m.handle, 2)
    }

    func testMalformedInputsNeverTrap() {
        var r = ZeppChunkReassembler()
        XCTAssertEqual(r.accept([]), [.ignored])
        XCTAssertEqual(r.accept([0x03]), [.dropped(.truncatedHeader)])
        XCTAssertEqual(r.accept([0x03, 0x01, 0x00, 0x01, 0x00, 0x05]), [.dropped(.truncatedHeader)])
        XCTAssertEqual(r.accept([0x99, 1, 2, 3, 4, 5]), [.ignored])
        XCTAssertEqual(r.accept([0x04, 0x00, 0x03]), [.ignored])
        XCTAssertEqual(r.accept(hex("04 00 03 01 02")), [.deviceAck(handle: 3, count: 2)])
        // First flag with a non-zero index.
        XCTAssertEqual(r.accept(hex("03 07 00 01 05 01 00 00 00 00 00 aa")), [.dropped(.chunkIndexGap(expected: 0, got: 5))])
        // Last chunk with less data than declared.
        XCTAssertEqual(r.accept(hex("03 07 00 01 00 05 00 00 00 00 00 aa")), [.dropped(.shortBody)])
        // More data than declared.
        XCTAssertEqual(r.accept(hex("03 05 00 01 00 01 00 00 00 00 00 aa bb")), [.dropped(.overflow)])
        // Encrypted, declared 10 bytes, but only 8 ciphertext bytes: not a whole AES block.
        XCTAssertEqual(r.accept(hex("03 0f 00 01 00 0a 00 00 00 00 00") + [UInt8](repeating: 0, count: 8)),
                       [.dropped(.shortBody)])
        // An absurd declared length is not preallocated; the message just never completes.
        XCTAssertEqual(r.accept(hex("03 01 00 02 00 ff ff ff ff 00 00 aa")), [])
    }

    func testRandomGarbageNeverTraps() {
        var gen = TestBytes(seed: 99)
        var r = ZeppChunkReassembler()
        var transport = ZeppChunkedTransport()
        transport.install(session: try! ZeppSessionCrypto(sessionKey: gen.bytes(16), sequenceSeed: 0))
        for _ in 0..<3000 {
            var bytes = gen.bytes(gen.int(0...40))
            if !bytes.isEmpty, gen.int(0...1) == 0 { bytes[0] = 0x03 }
            _ = r.accept(bytes)
            _ = transport.receive(bytes)
        }
    }
}
