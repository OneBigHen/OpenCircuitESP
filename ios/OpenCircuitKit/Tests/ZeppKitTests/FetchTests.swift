// History fetch (§6): worked example D byte for byte, then the ack policy — KEEP (03 09) on every
// path except a durably committed round under the delete policy — and every failure path.

import XCTest
@testable import ZeppKit

final class FetchTests: XCTestCase {

    private let plusTwo = TimeZone(secondsFromGMT: 7200)!
    /// 2026-09-29 00:00 at UTC+2.
    private let sinceD = date(1_790_632_800)
    private let startReplyD = hex("10 01 01 0c 00 00 00 ea 07 09 1d 00 05 00 08")
    private let dataPacketD = hex("00 8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39")
    private let transferDoneD = hex("10 02 01 39 62 bb d7")

    private func machine(_ plan: [(type: ZeppFetchType, since: Date)], now: Date = date(1_790_633_430),
                         policy: ZeppAckPolicy = .keepOnDevice, maxRounds: Int = 11) -> ZeppHistoryFetch {
        ZeppHistoryFetch(plan: plan, now: now,
                         configuration: .init(ackPolicy: policy, maxRoundsPerType: maxRounds, timeZone: plusTwo))
    }

    private func readyRound(_ actions: [ZeppHistoryFetch.Action], file: StaticString = #filePath,
                            line: UInt = #line) -> ZeppFetchRound? {
        for case .roundReady(let round) in actions { return round }
        XCTFail("no round in \(actions)", file: file, line: line)
        return nil
    }

    private func controls(_ actions: [ZeppHistoryFetch.Action]) -> [[UInt8]] {
        actions.compactMap { if case .sendControl(let b) = $0 { return b } else { return nil } }
    }

    // MARK: Worked example D (§6.2)

    func testWorkedExampleD() throws {
        var fetch = machine([(.hrv, sinceD)])
        XCTAssertEqual(fetch.start(), [.sendControl(hex("01 49 ea 07 09 1d 00 00 00 08"))])
        XCTAssertEqual(fetch.receiveControl(startReplyD), [.sendControl([0x02])])
        XCTAssertEqual(fetch.receiveData(dataPacketD), [])
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(transferDoneD)))
        XCTAssertEqual(round.type, .hrv)
        XCTAssertEqual(round.start, date(1_790_633_100))       // 00:05:00 at +02:00
        XCTAssertTrue(round.crcVerified)
        XCTAssertEqual(round.rawData, Array(dataPacketD.dropFirst()))
        XCTAssertEqual(round.parsed.records, .hrv([
            ZeppHRVReading(time: date(1_790_633_100), unknown: 0x08, milliseconds: 42),
            ZeppHRVReading(time: date(1_790_633_400), unknown: 0x08, milliseconds: 57),
        ]))
        XCTAssertEqual(round.nextSince, date(1_790_633_460))
        XCTAssertEqual(fetch.phase, .awaitingCommit)

        XCTAssertEqual(fetch.commit(roundID: round.id, durable: true), [.sendControl(hex("03 09"))])
        // next since (22:11Z) is after `now` (22:10:30Z): no second round.
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.finished])
        XCTAssertEqual(fetch.phase, .finished)
    }

    // MARK: Ack policy

    func testKeepPolicyNeverDeletesEvenAfterADurableCommit() throws {
        var fetch = machine([(.hrv, sinceD)], policy: .keepOnDevice)
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD); _ = fetch.receiveData(dataPacketD)
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(transferDoneD)))
        XCTAssertEqual(controls(fetch.commit(roundID: round.id, durable: true)), [[0x03, 0x09]])
    }

    func testDeletePolicyDeletesOnlyAfterADurableCommit() throws {
        var deleting = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = deleting.start(); _ = deleting.receiveControl(startReplyD); _ = deleting.receiveData(dataPacketD)
        let round = try XCTUnwrap(readyRound(deleting.receiveControl(transferDoneD)))
        XCTAssertEqual(controls(deleting.commit(roundID: round.id, durable: true)), [[0x03, 0x01]])

        var notDurable = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = notDurable.start(); _ = notDurable.receiveControl(startReplyD); _ = notDurable.receiveData(dataPacketD)
        let round2 = try XCTUnwrap(readyRound(notDurable.receiveControl(transferDoneD)))
        XCTAssertEqual(controls(notDurable.commit(roundID: round2.id, durable: false)), [[0x03, 0x09]])
    }

    func testCommitForAnotherRoundIsIgnored() throws {
        var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD); _ = fetch.receiveData(dataPacketD)
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(transferDoneD)))
        XCTAssertEqual(fetch.commit(roundID: round.id + 1, durable: true), [])
        XCTAssertEqual(fetch.phase, .awaitingCommit)
        // A commit before any round, or a second commit, does nothing either.
        XCTAssertEqual(controls(fetch.commit(roundID: round.id, durable: true)), [[0x03, 0x01]])
        XCTAssertEqual(fetch.commit(roundID: round.id, durable: true), [])
    }

    // MARK: Empty, refused, failed rounds (all keep, or no ack at all)

    func testZeroLengthRoundKeepsAndMovesOn() {
        var fetch = machine([(.temperature, sinceD), (.hrv, sinceD)])
        _ = fetch.start()
        XCTAssertEqual(fetch.receiveControl(hex("10 01 01 00 00 00 00 ea 07 09 1d 00 00 00 08")),
                       [.noData(type: .temperature), .sendControl(hex("03 09"))])
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.sendControl(hex("01 49 ea 07 09 1d 00 00 00 08"))])
    }

    func testRefusedTypeIsSkippedWithoutAnAck() {
        var fetch = machine([(.pai, sinceD), (.hrv, sinceD)])
        _ = fetch.start()
        XCTAssertEqual(fetch.receiveControl(hex("10 01 04")), [
            .roundFailed(type: .pai, failure: .startRefused(status: 0x04)),
            .sendControl(hex("01 49 ea 07 09 1d 00 00 00 08")),
        ])
    }

    func testCRCMismatchKeepsAndRetriesOnceFromTheSameSince() {
        var fetch = machine([(.hrv, sinceD)])
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD); _ = fetch.receiveData(dataPacketD)
        XCTAssertEqual(fetch.receiveControl(hex("10 02 01 39 62 bb d6")), [
            .roundFailed(type: .hrv, failure: .crcMismatch(expected: 0xd6bb_6239, computed: 0xd7bb_6239)),
            .sendControl(hex("03 09")),
        ])
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.sendControl(hex("01 49 ea 07 09 1d 00 00 00 08"))])
        _ = fetch.receiveControl(startReplyD); _ = fetch.receiveData(dataPacketD)
        XCTAssertEqual(controls(fetch.receiveControl(hex("10 02 01 00 00 00 00"))), [[0x03, 0x09]])
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.finished])     // retry budget spent
    }

    func testPacketCounterGapKeeps() {
        var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD)
        XCTAssertEqual(fetch.receiveData([0x01] + dataPacketD.dropFirst()), [
            .roundFailed(type: .hrv, failure: .packetCounterGap(expected: 0, got: 1)),
            .sendControl(hex("03 09")),
        ])
        // Late packets and the transfer-done of the dead round are ignored.
        XCTAssertEqual(fetch.receiveData(dataPacketD), [])
        XCTAssertEqual(fetch.receiveControl(transferDoneD), [])
    }

    func testOverflowShortDataFailedTransferAndBadReplyLengthsKeep() {
        func failure(_ steps: (inout ZeppHistoryFetch) -> [ZeppHistoryFetch.Action]) -> [ZeppHistoryFetch.Action] {
            var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
            _ = fetch.start(); _ = fetch.receiveControl(startReplyD)
            return steps(&fetch)
        }
        XCTAssertEqual(failure { $0.receiveData(dataPacketD + [0xAA]) },
                       [.roundFailed(type: .hrv, failure: .dataOverflow(expected: 12, received: 13)), .sendControl(hex("03 09"))])
        XCTAssertEqual(failure { f in _ = f.receiveData(Array(dataPacketD.prefix(7))); return f.receiveControl(hex("10 02 01")) },
                       [.roundFailed(type: .hrv, failure: .lengthMismatch(expected: 12, received: 6)), .sendControl(hex("03 09"))])
        XCTAssertEqual(failure { f in _ = f.receiveData(dataPacketD); return f.receiveControl(hex("10 02 05")) },
                       [.roundFailed(type: .hrv, failure: .transferFailed(status: 5)), .sendControl(hex("03 09"))])
        XCTAssertEqual(failure { f in _ = f.receiveData(dataPacketD); return f.receiveControl(hex("10 02 01 39 62")) },
                       [.roundFailed(type: .hrv, failure: .malformedTransferDone), .sendControl(hex("03 09"))])
    }

    func testMalformedStartRepliesKeep() {
        for reply in [hex("10 01"), hex("10 01 01 0c 00 00 00 ea 07 09 1d 00 05 00"),            // 14 B
                      hex("10 01 01 0c 00 00 00 ea 07 0d 1d 00 05 00 08"),                       // month 13
                      hex("10 01 01 0c 00 00 00 ea 07 09 1d 00 05 00 08 00 00")] {               // 17 B
            var fetch = machine([(.hrv, sinceD)])
            _ = fetch.start()
            let actions = fetch.receiveControl(reply)
            XCTAssertEqual(controls(actions), [[0x03, 0x09]], ZeppHex.string(reply))
            XCTAssertTrue(actions.contains(.roundFailed(type: .hrv, failure: .malformedStartReply)))
        }
        var sixteen = machine([(.hrv, sinceD)])
        _ = sixteen.start()
        XCTAssertEqual(sixteen.receiveControl(startReplyD + [0x00]), [.sendControl([0x02])])
    }

    func testLengthRuleViolationKeeps() {
        var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start()
        _ = fetch.receiveControl(hex("10 01 01 07 00 00 00 ea 07 09 1d 00 05 00 08"))
        _ = fetch.receiveData([0x00, 1, 2, 3, 4, 5, 6, 7])
        let actions = fetch.receiveControl(hex("10 02 01"))
        XCTAssertEqual(actions, [.roundFailed(type: .hrv, failure: .parseFailed(.lengthViolation(type: .hrv, length: 7))),
                                 .sendControl(hex("03 09"))])
    }

    func testAbortMidRoundKeeps() {
        var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD)
        XCTAssertEqual(fetch.abort(), [.roundFailed(type: .hrv, failure: .aborted), .sendControl(hex("03 09"))])
        XCTAssertEqual(fetch.phase, .finished)
        XCTAssertEqual(fetch.receiveControl(transferDoneD), [])

        var idle = machine([(.hrv, sinceD)])
        XCTAssertEqual(idle.abort(), [])
    }

    // MARK: Rounds and cursors (§6.4)

    /// Activity announces its length in records (minutes), not bytes (§6.2, seen on hardware).
    private func activityStart(_ minutes: Int, at local: [UInt8]) -> [UInt8] {
        [0x10, 0x01, 0x01] + le32(UInt32(minutes)) + local
    }

    func testContinuesFromLastRecordPlusOneMinuteUntilEmpty() throws {
        var fetch = machine([(.activity, sinceD)], now: date(1_790_700_000))
        _ = fetch.start()
        // First record at 00:00 local (+02:00), three minutes of data.
        _ = fetch.receiveControl(activityStart(3, at: hex("ea 07 09 1d 00 00 00 08")))
        _ = fetch.receiveData([0x00] + [UInt8](repeating: 0x01, count: 24))
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01"))))
        XCTAssertEqual(round.nextSince, date(1_790_632_800 + 180))
        XCTAssertFalse(round.crcVerified)
        _ = fetch.commit(roundID: round.id, durable: false)
        // Next round starts at 00:03 local.
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.sendControl(hex("01 01 ea 07 09 1d 00 03 00 08"))])
        _ = fetch.receiveControl(activityStart(0, at: hex("ea 07 09 1d 00 03 00 08")))
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.finished])
    }

    func testRoundsPerTypeAreBounded() throws {
        var fetch = machine([(.activity, sinceD), (.hrv, sinceD)], now: date(1_790_700_000), maxRounds: 3)
        _ = fetch.start()
        var starts = 0
        for i in 0..<3 {
            starts += 1
            let minute = UInt8(i)
            _ = fetch.receiveControl(activityStart(1, at: [0xea, 0x07, 0x09, 0x1d, 0x00, minute, 0x00, 0x08]))
            _ = fetch.receiveData([0x00] + [UInt8](repeating: 0, count: 8))
            let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01"))))
            _ = fetch.commit(roundID: round.id, durable: false)
            let next = fetch.receiveControl(hex("10 03 01"))
            if i < 2 {
                XCTAssertEqual(controls(next).first?[1], 0x01)            // another activity round
            } else {
                XCTAssertEqual(controls(next), [hex("01 49 ea 07 09 1d 00 00 00 08")])   // moved on
            }
        }
        XCTAssertEqual(starts, 3)
    }

    func testNeverAsksForASinceInTheFuture() throws {
        var fetch = machine([(.activity, sinceD)], now: date(1_790_632_800 + 120))
        _ = fetch.start()
        _ = fetch.receiveControl(activityStart(3, at: hex("ea 07 09 1d 00 00 00 08")))
        _ = fetch.receiveData([0x00] + [UInt8](repeating: 0, count: 24))
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01"))))
        _ = fetch.commit(roundID: round.id, durable: false)
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.finished])
    }

    func testStartReplyUsesItsOwnOffsetNotThePhonesZone() throws {
        // Phone in UTC; the strap still thinks it is UTC+2 (e.g. before a time set after travel).
        var fetch = ZeppHistoryFetch(plan: [(.activity, sinceD)], now: date(1_790_700_000),
                                     configuration: .init(timeZone: utc))
        XCTAssertEqual(fetch.start(), [.sendControl(hex("01 01 ea 07 09 1c 16 00 00 00"))])  // 22:00 at +00
        _ = fetch.receiveControl(activityStart(1, at: hex("ea 07 09 1d 00 00 00 08")))       // 00:00 at +02
        _ = fetch.receiveData([0x00] + [UInt8](repeating: 0, count: 8))
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01"))))
        XCTAssertEqual(round.start, date(1_790_632_800))
    }

    func testUnexpectedControlBytesAreIgnored() {
        var fetch = machine([(.hrv, sinceD)])
        _ = fetch.start()
        for bytes in [[], [0x10], [0x11, 0x01, 0x01], hex("10 02 01"), hex("10 03 01"), hex("10 07 01")] as [[UInt8]] {
            XCTAssertEqual(fetch.receiveControl(bytes), [], ZeppHex.string(bytes))
        }
        XCTAssertEqual(fetch.receiveData(dataPacketD), [])
        XCTAssertEqual(fetch.phase, .awaitingStartReply)
    }

    func testRandomControlAndDataNeverTrapAndNeverDelete() {
        var gen = TestBytes(seed: 2024)
        for _ in 0..<300 {
            var fetch = machine([(.hrv, sinceD), (.activity, sinceD), (.spo2, sinceD)],
                                now: date(1_790_700_000), policy: .deleteAfterDurableCommit)
            var sent = controls(fetch.start())
            for _ in 0..<40 {
                var bytes = gen.bytes(gen.int(0...20))
                if bytes.count >= 2, gen.int(0...1) == 0 { bytes[0] = 0x10; bytes[1] = UInt8(gen.int(1...3)) }
                if bytes.count >= 3, gen.int(0...1) == 0 { bytes[2] = 0x01 }
                let actions = gen.int(0...1) == 0 ? fetch.receiveControl(bytes) : fetch.receiveData(bytes)
                sent += controls(actions)
                // Never confirm a commit: nothing may ever be deleted.
                for case .roundReady(let r) in actions { sent += controls(fetch.commit(roundID: r.id, durable: false)) }
            }
            XCTAssertFalse(sent.contains([0x03, 0x01]))
        }
    }

    // MARK: Against the simulated strap (Path A)

    func testFullFetchAgainstTheSimulatedStrapKeepsEverything() {
        let device = FakeZeppDevice(authKey: [UInt8](repeating: 0, count: 16), privateKey: SpecC.strapDrawnPrivate,
                                    random: SpecC.strapRandom)
        device.fetchData[.hrv] = (start: hex("ea 07 09 1d 00 05 00 08"), data: Array(dataPacketD.dropFirst()))
        var temperature = [UInt8]()
        for centi in [3312, 3325, 0x7fff] as [Int16] {
            temperature += le16(0x7fff) + le16(UInt16(bitPattern: centi)) + le16(0x5a5a) + le16(0x5a5a)
        }
        // Starts 00:04 local (22:04Z): its next *since* (22:07Z) is after `now`, so one round only.
        device.fetchData[.temperature] = (start: hex("ea 07 09 1d 00 04 00 08"), data: temperature)
        device.refuseTypes = [.spo2]
        device.dataPacketLength = 5

        var fetch = machine([(.hrv, sinceD), (.spo2, sinceD), (.temperature, sinceD), (.restingHeartRate, sinceD)],
                            now: date(1_790_633_130))
        var queue = fetch.start()
        var rounds = [ZeppFetchRound]()
        var failures = [ZeppRoundFailure]()
        var finished = false
        var steps = 0
        while !queue.isEmpty, steps < 1000 {
            steps += 1
            let action = queue.removeFirst()
            switch action {
            case .sendControl(let bytes):
                for n in device.phoneWrote(ZeppWrite(.activityControl, bytes)) {
                    queue += n.characteristic == .activityData ? fetch.receiveData(n.bytes) : fetch.receiveControl(n.bytes)
                }
            case .roundReady(let round):
                rounds.append(round)
                queue += fetch.commit(roundID: round.id, durable: true)
            case .roundFailed(_, let failure):
                failures.append(failure)
            case .noData:
                break
            case .finished:
                finished = true
            }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(rounds.map(\.type), [.hrv, .temperature])
        XCTAssertEqual(failures, [.startRefused(status: 0x04)])
        XCTAssertEqual(device.fetchAcks, [0x09, 0x09, 0x09])   // hrv, temperature, resting HR (empty)
        XCTAssertEqual(device.fetchStarts.count, 4)
        guard case .temperature(let minutes) = rounds[1].parsed.records else { return XCTFail() }
        XCTAssertEqual(minutes.map(\.celsius), [33.12, 33.25, nil])
    }
}
