// The fetch machine's ack-safety invariant against a mostly-honest but hostile strap (adapted from
// the #219 review's reactive fuzz probe). `03 01` may only follow `commit(roundID:durable: true)`
// for the round just delivered, under `.deleteAfterDurableCommit`, and only for a CRC-verified
// round: the probe found a length-preserving corruption with no CRC that was delete-acked (N3).
//
// Deterministic (xorshift seed), so any failure reproduces.

import XCTest
@testable import ZeppKit

final class FetchAckSafetyFuzzTests: XCTestCase {

    private func pick<T>(_ g: inout TestBytes, _ options: [T]) -> T { options[g.int(0...(options.count - 1))] }

    private enum PeerEvent { case control([UInt8]), data([UInt8]), commit(id: Int, durable: Bool), abort }

    /// Start replies with boundary statuses, lengths (up to ff ff ff ff) and timestamps.
    private func hostileStartReply(_ g: inout TestBytes, since: Date) -> [UInt8] {
        let status: UInt8 = pick(&g, [0x01, 0x01, 0x01, 0x01, 0x02, 0x00, 0xFF])
        let lengths: [UInt32] = [0, 0, 1, 6, 8, 12, 30, 65, 66, 102, 594, 720, 0xFFFF_FFFF,
                                 UInt32(truncatingIfNeeded: g.next() & 0x3FF)]
        let length = pick(&g, lengths)
        var starts = [[UInt8]]()
        starts.append(ZeppFetchTimestamp.encode(since, timeZone: utc))
        starts.append([UInt8](repeating: 0, count: 8))
        starts.append([0x3a, 0x08, 0x02, 0x06, 0x02, 0x1c, 0x10, 0xf0])     // the §6.2 far-future sentinel
        starts.append(g.bytes(8))
        starts.append([0xff, 0xff, 12, 31, 23, 59, 59, 0x7f])
        starts.append([0, 0, 1, 1, 0, 0, 0, 0x80])
        var reply: [UInt8] = [0x10, 0x01, status] + le32(length)
        reply += pick(&g, starts)
        if g.int(0...1) == 0 { reply.append(0x00) }
        if g.int(0...9) == 0 { reply = Array(reply.prefix(g.int(0...reply.count))) }
        if g.int(0...19) == 0 { reply += g.bytes(g.int(1...4)) }
        return reply
    }

    /// Random data of the right shape for `n` records of `type` (§6.5 length rules).
    private func honestData(_ type: ZeppFetchType, records n: Int, _ g: inout TestBytes) -> [UInt8] {
        switch type {
        case .spo2: return n == 0 ? [] : [0x02] + g.bytes(n * ZeppSpO2Reading.recordLength)
        case .sleepSpO2: return n == 0 ? [] : [0x02] + g.bytes(n * ZeppSleepSpO2Reading.recordLength)
        case .activity, .temperature, .sleepRespiratoryRate: return g.bytes(n * 8)
        case .manualHeartRate, .restingHeartRate, .maxHeartRate, .hrv: return g.bytes(n * 6)
        case .manualStress: return g.bytes(n * 5)
        case .pai: return g.bytes(n * ZeppPAIRecord.recordLength)
        case .sleepSession: return g.bytes(n * ZeppSleepSession.recordLength)
        case .autoStress: return g.bytes(n)
        }
    }

    /// A strap that answers what the machine actually sent (start reply per the type's length unit,
    /// counted packets, transfer done with or without a CRC, `10 03 01`), with hostile mutations at
    /// random: malformed start replies, counter skips, extra/short/lost packets, bad CRCs, late
    /// `10 02`s, noise, wrong-round and non-durable commits, aborts.
    func testReactiveMostlyHonestPeerOnlyGetsDeleteAcksForDurableCRCVerifiedRounds() {
        var g = TestBytes(seed: 0x2190_0009)
        var readyRounds = 0, deleteAcks = 0, keepAcks = 0, failed = 0, finished = 0
        var corruptDelivered = 0, corruptDeleted = 0, uncheckedDurableCommits = 0
        let now = date(1_790_700_000)
        for iteration in 0..<3_000 {
            let policy: ZeppAckPolicy = iteration % 2 == 0 ? .keepOnDevice : .deleteAfterDurableCommit
            let types = (0..<g.int(1...4)).map { _ in pick(&g, ZeppFetchType.allCases) }
            let since = now.addingTimeInterval(-TimeInterval(60 * g.int(1...3_000)))
            var machine = ZeppHistoryFetch(plan: types.map { ($0, since) }, now: now,
                                           configuration: .init(ackPolicy: policy, timeZone: utc))
            var pending: ZeppFetchRound?
            var roundData: [UInt8] = []
            var roundMutated = false
            var pendingCorrupt = false
            var queue: [PeerEvent] = []

            func react(_ actions: [ZeppHistoryFetch.Action], to call: PeerEvent?) {
                for action in actions {
                    switch action {
                    case .sendControl(let bytes) where bytes == [0x03, 0x01]:
                        deleteAcks += 1
                        XCTAssertEqual(policy, .deleteAfterDurableCommit, "03 01 under keepOnDevice")
                        guard case .commit(let id, let durable)? = call else {
                            return XCTFail("03 01 emitted outside commit")
                        }
                        XCTAssertTrue(durable, "03 01 for a non-durable commit")
                        XCTAssertEqual(id, pending?.id, "03 01 for a round other than the one delivered")
                        XCTAssertEqual(pending?.crcVerified, true, "03 01 for a round without a CRC")
                        if pendingCorrupt { corruptDeleted += 1 }
                        queue.append(.control([0x10, 0x03, 0x01]))
                    case .sendControl(let bytes) where bytes.first == 0x03:
                        XCTAssertEqual(bytes, [0x03, 0x09])
                        keepAcks += 1
                        if case .commit(let id, true)? = call, id == pending?.id, pending?.crcVerified == false,
                           policy == .deleteAfterDurableCommit {
                            uncheckedDurableCommits += 1
                        }
                        if g.int(0...4) == 0 {                   // late transfer done after a mid-transfer ack (§6.3)
                            queue.append(.control([0x10, 0x02, 0x01] + le32(ZeppCRC32.checksum(roundData))))
                        }
                        queue.append(.control([0x10, 0x03, 0x01]))
                    case .sendControl(let bytes) where bytes.first == 0x01 && bytes.count == 10:
                        guard let type = ZeppFetchType(rawValue: bytes[1]) else { return XCTFail("bad start \(bytes)") }
                        let n = pick(&g, [0, 0, 1, 2, 3, 7, 30])
                        roundData = honestData(type, records: n, &g)
                        roundMutated = false
                        let announced = type == .activity ? roundData.count / 8 : roundData.count
                        var reply: [UInt8] = [0x10, 0x01, 0x01] + le32(UInt32(announced))
                        reply += Array(bytes[2..<10])
                        reply.append(0x00)
                        if g.int(0...9) == 0 { reply = hostileStartReply(&g, since: since) }
                        queue.append(.control(reply))
                    case .sendControl(let bytes) where bytes == [0x02]:
                        var rest = roundData
                        var counter: UInt8 = 0
                        while !rest.isEmpty {
                            let take = min(rest.count, g.int(1...244))
                            var packet: [UInt8] = [counter]
                            packet += rest.prefix(take)
                            rest.removeFirst(take)
                            counter &+= 1
                            switch g.int(0...59) {
                            case 0: packet[0] &+= 1; roundMutated = true        // counter skip
                            case 1: packet.append(0xEE); roundMutated = true    // one extra byte
                            case 2: packet.removeLast(); roundMutated = true    // one byte short
                            case 3: roundMutated = true; continue               // packet lost
                            default: break
                            }
                            queue.append(.data(packet))
                        }
                        var crc = ZeppCRC32.checksum(roundData)
                        if g.int(0...14) == 0 { crc ^= 0x0100 }
                        let done: [UInt8] = g.int(0...14) == 0 ? [0x10, 0x02, 0x01] : [0x10, 0x02, 0x01] + le32(crc)
                        queue.append(.control(done))
                    case .sendControl(let bytes):
                        XCTFail("unexpected control \(bytes)")
                    case .roundReady(let round):
                        readyRounds += 1
                        pending = round
                        // A delivered round can differ from what the peer meant to send ONLY when the
                        // peer mutated it AND the transfer done carried no CRC (3-byte form).
                        pendingCorrupt = round.rawData != roundData
                        if pendingCorrupt {
                            corruptDelivered += 1
                            XCTAssertTrue(roundMutated && !round.crcVerified, "corrupt round delivered despite a CRC")
                        }
                        let id = g.int(0...9) == 0 ? round.id + g.int(1...3) : round.id
                        queue.append(.commit(id: id, durable: g.int(0...2) > 0))
                    case .roundFailed:
                        failed += 1
                    case .noData:
                        break
                    case .finished:
                        finished += 1
                    }
                }
            }

            react(machine.start(), to: nil)
            var steps = 0
            while !queue.isEmpty, steps < 3_000, machine.phase != .finished {
                steps += 1
                if g.int(0...39) == 0 { queue.insert(.control(g.bytes(g.int(0...18))), at: g.int(0...queue.count)) }
                if g.int(0...39) == 0 { queue.insert(.data(g.bytes(g.int(0...30))), at: g.int(0...queue.count)) }
                if g.int(0...299) == 0 { queue.insert(.abort, at: 0) }
                let event = queue.removeFirst()
                switch event {
                case .control(let bytes): react(machine.receiveControl(bytes), to: event)
                case .data(let bytes): react(machine.receiveData(bytes), to: event)
                case .commit(let id, let durable): react(machine.commit(roundID: id, durable: durable), to: event)
                case .abort: react(machine.abort(), to: event)
                }
            }
        }
        XCTAssertEqual(corruptDeleted, 0, "a corrupt round was delete-acked")
        // Coverage floors, so the invariant is not vacuously true.
        XCTAssertGreaterThan(readyRounds, 1_000)
        XCTAssertGreaterThan(deleteAcks, 200)
        XCTAssertGreaterThan(keepAcks, 1_000)
        XCTAssertGreaterThan(failed, 100)
        XCTAssertGreaterThan(finished, 1_000)
        XCTAssertGreaterThan(uncheckedDurableCommits, 0, "no durable commit of a CRC-less round was exercised")
    }
}
