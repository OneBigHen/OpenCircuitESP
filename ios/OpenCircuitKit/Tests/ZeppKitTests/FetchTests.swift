// History fetch (§6): worked example D byte for byte, then the ack policy — KEEP (03 09) on every
// path except a durably committed round under the delete policy — and every failure path.

import XCTest
@testable import ZeppKit
import ZeppKitTesting

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

    func testDeletePolicyKeepsARoundWithoutACRC() throws {
        // The 3-byte transfer done carries no CRC: nothing proves the data arrived intact (#219 review N3).
        var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD); _ = fetch.receiveData(dataPacketD)
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01"))))
        XCTAssertFalse(round.crcVerified)
        XCTAssertEqual(controls(fetch.commit(roundID: round.id, durable: true)), [[0x03, 0x09]])

        var activity = machine([(.activity, sinceD)], policy: .deleteAfterDurableCommit)
        _ = activity.start()
        _ = activity.receiveControl(activityStart(3, at: hex("ea 07 09 1d 00 00 00 08")))
        _ = activity.receiveData([0x00] + threeMinutes)
        let noCRC = try XCTUnwrap(readyRound(activity.receiveControl(hex("10 02 01"))))
        XCTAssertEqual(controls(activity.commit(roundID: noCRC.id, durable: true)), [[0x03, 0x09]])
    }

    func testLengthPreservingCorruptionWithoutACRCIsDeliveredButNeverDeleted() throws {
        // The review's fuzz case: one packet gains a byte and a later one loses a byte, so the length
        // still matches; with no CRC the round parses, and it must still be kept on the strap.
        let data = Array(dataPacketD.dropFirst())
        var fetch = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start(); _ = fetch.receiveControl(startReplyD)
        XCTAssertEqual(fetch.receiveData([0x00] + data.prefix(6) + [0xEE]), [])
        XCTAssertEqual(fetch.receiveData([0x01] + data.dropFirst(6).dropLast()), [])
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01"))))
        XCTAssertNotEqual(round.rawData, data)
        XCTAssertFalse(round.crcVerified)
        XCTAssertEqual(controls(fetch.commit(roundID: round.id, durable: true)), [[0x03, 0x09]])
        // With the CRC, the same corruption fails the round instead.
        var checked = machine([(.hrv, sinceD)], policy: .deleteAfterDurableCommit)
        _ = checked.start(); _ = checked.receiveControl(startReplyD)
        _ = checked.receiveData([0x00] + data.prefix(6) + [0xEE])
        _ = checked.receiveData([0x01] + data.dropFirst(6).dropLast())
        XCTAssertEqual(controls(checked.receiveControl(transferDoneD)), [[0x03, 0x09]])
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

    // MARK: Hardware findings (§10.1): activity length unit, the two empty start replies

    /// Three made-up activity minutes and the zlib CRC-32 of those 24 bytes.
    private let threeMinutes = hex("01 20 0c 48 00 00 00 00 01 18 05 4a 00 00 00 00 73 00 00 ff 00 00 00 00")
    private let threeMinutesDone = hex("10 02 01 5e 58 b9 da")
    /// The all-zero "nothing more" start reply, in the 16-byte form.
    private let allZeroEmpty = hex("10 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00")
    /// The far-future sentinel "nothing more" start reply (year 0x083a = 2106, at UTC−4).
    private let sentinelEmpty = hex("10 01 01 00 00 00 00 3a 08 02 06 02 1c 10 f0 00")

    func testActivityLengthCountsRecords() throws {
        var fetch = machine([(.activity, sinceD)])
        _ = fetch.start()
        // Length 3 = three 8-byte records; 16-byte form with the trailing 00.
        XCTAssertEqual(fetch.receiveControl(hex("10 01 01 03 00 00 00 ea 07 09 1d 00 00 00 08 00")),
                       [.sendControl([0x02])])
        XCTAssertEqual(fetch.receiveData([0x00] + threeMinutes.prefix(19)), [])
        XCTAssertEqual(fetch.receiveData([0x01] + threeMinutes.dropFirst(19)), [])
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(threeMinutesDone)))
        XCTAssertTrue(round.crcVerified)
        XCTAssertEqual(round.rawData, threeMinutes)
        guard case .activity(let minutes) = round.parsed.records else { return XCTFail() }
        XCTAssertEqual(minutes.map(\.time), [date(1_790_632_800), date(1_790_632_860), date(1_790_632_920)])
        XCTAssertEqual(minutes.map(\.steps), [12, 5, 0])
        XCTAssertEqual(minutes.map(\.heartRate), [72, 74, nil])
        XCTAssertEqual(controls(fetch.commit(roundID: round.id, durable: true)), [[0x03, 0x09]])
    }

    func testActivityThirtyMinuteWindowInOnePacket() throws {
        // The shape seen on hardware: length 30, then one 241-byte packet (counter + 240 bytes).
        // The bytes are made up.
        let data = [UInt8]((0..<30).flatMap { _ in hex("01 10 02 46 00 00 00 00") })
        var fetch = machine([(.activity, sinceD)])
        _ = fetch.start()
        XCTAssertEqual(fetch.receiveControl(hex("10 01 01 1e 00 00 00 ea 07 09 1d 00 00 00 08 00")),
                       [.sendControl([0x02])])
        XCTAssertEqual(fetch.receiveData([0x00] + data), [])
        let round = try XCTUnwrap(readyRound(fetch.receiveControl(hex("10 02 01 05 38 5b 31"))))
        XCTAssertEqual(round.parsed.records.count, 30)
        XCTAssertEqual(round.nextSince, date(1_790_632_800 + 30 * 60))
    }

    func testActivityOverflowAndShortfallAreCountedInBytes() {
        func failure(_ steps: (inout ZeppHistoryFetch) -> [ZeppHistoryFetch.Action]) -> [ZeppHistoryFetch.Action] {
            var fetch = machine([(.activity, sinceD)], policy: .deleteAfterDurableCommit)
            _ = fetch.start()
            _ = fetch.receiveControl(activityStart(3, at: hex("ea 07 09 1d 00 00 00 08")))
            return steps(&fetch)
        }
        XCTAssertEqual(failure { $0.receiveData([0x00] + threeMinutes + [0xAA]) }, [
            .roundFailed(type: .activity, failure: .dataOverflow(expected: 24, received: 25)),
            .sendControl(hex("03 09")),
        ])
        XCTAssertEqual(failure { f in _ = f.receiveData([0x00] + threeMinutes.prefix(16)); return f.receiveControl(hex("10 02 01")) }, [
            .roundFailed(type: .activity, failure: .lengthMismatch(expected: 24, received: 16)),
            .sendControl(hex("03 09")),
        ])
    }

    func testActivityCRCMismatchKeepsAndReportsBothValues() {
        var fetch = machine([(.activity, sinceD)], policy: .deleteAfterDurableCommit)
        _ = fetch.start()
        _ = fetch.receiveControl(activityStart(3, at: hex("ea 07 09 1d 00 00 00 08")))
        _ = fetch.receiveData([0x00] + threeMinutes)
        let failure = ZeppRoundFailure.crcMismatch(expected: 0x1122_3344, computed: 0xdab9_585e)
        XCTAssertEqual(fetch.receiveControl(hex("10 02 01 44 33 22 11")),
                       [.roundFailed(type: .activity, failure: failure), .sendControl(hex("03 09"))])
        XCTAssertEqual(failure.description, "CRC mismatch, announced 0x11223344, computed 0xdab9585e")
    }

    func testAllZeroEmptyReplyIsAnEmptyRoundWithOneAckAndNoRetry() {
        var fetch = machine([(.temperature, sinceD), (.hrv, sinceD)])
        var sent = controls(fetch.start())
        let empty = fetch.receiveControl(allZeroEmpty)
        XCTAssertEqual(empty, [.noData(type: .temperature), .sendControl(hex("03 09"))])
        sent += controls(empty)
        let next = fetch.receiveControl(hex("10 03 01"))
        XCTAssertEqual(next, [.sendControl(hex("01 49 ea 07 09 1d 00 00 00 08"))])   // hrv, not a retry
        sent += controls(next)
        XCTAssertEqual(sent.filter { $0 == [0x03, 0x09] }.count, 1)
        XCTAssertEqual(sent.filter { $0.starts(with: [0x01, 0x2e]) }.count, 1)
    }

    func testSentinelEmptyReplyIsStillAnEmptyRound() {
        var fetch = machine([(.manualHeartRate, sinceD), (.hrv, sinceD)])
        _ = fetch.start()
        XCTAssertEqual(fetch.receiveControl(sentinelEmpty), [.noData(type: .manualHeartRate), .sendControl(hex("03 09"))])
        XCTAssertEqual(fetch.receiveControl(hex("10 03 01")), [.sendControl(hex("01 49 ea 07 09 1d 00 00 00 08"))])
    }

    func testEmptyReplyOfTheWrongLengthIsStillMalformed() {
        for reply in [Array(allZeroEmpty.prefix(14)), allZeroEmpty + [0x00]] {
            var fetch = machine([(.hrv, sinceD)])
            _ = fetch.start()
            XCTAssertEqual(fetch.receiveControl(reply),
                           [.roundFailed(type: .hrv, failure: .malformedStartReply), .sendControl(hex("03 09"))],
                           ZeppHex.string(reply))
        }
    }

    func testDataRoundThenAllZeroEmptyReplyEndsTheTypeCleanly() throws {
        var fetch = machine([(.temperature, sinceD), (.hrv, sinceD)], now: date(1_790_700_000))
        var actions = fetch.start()
        // Two made-up minutes of temperature from 00:00 local, with a CRC.
        var data = [UInt8]()
        for centi: UInt16 in [3312, 3318] {
            data += le16(0x7fff) + le16(centi) + le16(0x5a5a) + le16(0x5a5a)
        }
        actions += fetch.receiveControl(hex("10 01 01 10 00 00 00 ea 07 09 1d 00 00 00 08 00"))
        actions += fetch.receiveData([0x00] + data)
        let done = fetch.receiveControl([0x10, 0x02, 0x01] + le32(ZeppCRC32.checksum(data)))
        actions += done
        let round = try XCTUnwrap(readyRound(done))
        actions += fetch.commit(roundID: round.id, durable: false)
        let followUp = fetch.receiveControl(hex("10 03 01"))
        XCTAssertEqual(followUp, [.sendControl(hex("01 2e ea 07 09 1d 00 02 00 08"))])   // since 00:02 local
        actions += followUp
        actions += fetch.receiveControl(allZeroEmpty)
        actions += fetch.receiveControl(hex("10 03 01"))
        XCTAssertFalse(actions.contains { if case .roundFailed = $0 { return true } else { return false } })
        XCTAssertEqual(actions.filter { $0 == .noData(type: .temperature) }.count, 1)
        XCTAssertEqual(controls(actions), [
            hex("01 2e ea 07 09 1d 00 00 00 08"), [0x02], [0x03, 0x09],
            hex("01 2e ea 07 09 1d 00 02 00 08"), [0x03, 0x09],
            hex("01 49 ea 07 09 1d 00 00 00 08"),
        ])
    }

    func testFailureDescriptionsGiveBytesAndHex() {
        XCTAssertEqual(ZeppRoundFailure.dataOverflow(expected: 240, received: 248).description,
                       "data overflow, announced 240 B, received 248 B")
        XCTAssertEqual(ZeppRoundFailure.startRefused(status: 0x04).description, "start refused, status 04")
        XCTAssertEqual("\(ZeppRoundFailure.malformedStartReply)", "malformed start reply")
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

    /// Runs a fetch against the simulated strap, committing every round as durable.
    private func drive(_ fetch: inout ZeppHistoryFetch, _ device: FakeZeppDevice)
        -> (rounds: [ZeppFetchRound], failures: [ZeppRoundFailure], empty: [ZeppFetchType], finished: Bool) {
        var queue = fetch.start()
        var rounds = [ZeppFetchRound]()
        var failures = [ZeppRoundFailure]()
        var empty = [ZeppFetchType]()
        var finished = false
        var steps = 0
        while !queue.isEmpty, steps < 1000 {
            steps += 1
            switch queue.removeFirst() {
            case .sendControl(let bytes):
                for n in device.phoneWrote(ZeppWrite(.activityControl, bytes)) {
                    queue += n.characteristic == .activityData ? fetch.receiveData(n.bytes) : fetch.receiveControl(n.bytes)
                }
            case .roundReady(let round):
                rounds.append(round)
                queue += fetch.commit(roundID: round.id, durable: true)
            case .roundFailed(_, let failure):
                failures.append(failure)
            case .noData(let type):
                empty.append(type)
            case .finished:
                finished = true
            }
        }
        return (rounds, failures, empty, finished)
    }

    func testActivityAndAllZeroEmptyRepliesAgainstTheSimulatedStrap() throws {
        let device = FakeZeppDevice(authKey: [UInt8](repeating: 0, count: 16), privateKey: SpecC.strapDrawnPrivate,
                                    random: SpecC.strapRandom)
        // Starts 00:00 local (22:00Z); its next *since* (22:03Z) is after `now`, so one round only.
        device.fetchData[.activity] = (start: hex("ea 07 09 1d 00 00 00 08"), data: threeMinutes)
        device.startReplyTrailingZero = true
        device.emptyStartAllZero = true
        device.dataPacketLength = 10

        var fetch = machine([(.activity, sinceD), (.temperature, sinceD), (.hrv, sinceD)], now: date(1_790_632_900))
        let run = drive(&fetch, device)
        XCTAssertTrue(run.finished)
        XCTAssertEqual(run.failures, [])
        XCTAssertEqual(run.empty, [.temperature, .hrv])
        XCTAssertEqual(device.fetchStarts.count, 3)                // no retries
        XCTAssertEqual(device.fetchAcks, [0x09, 0x09, 0x09])
        let round = try XCTUnwrap(run.rounds.first)
        XCTAssertEqual(run.rounds.count, 1)
        XCTAssertTrue(round.crcVerified)
        XCTAssertEqual(round.parsed.records.count, 3)
    }

    // MARK: Announced length cap (#219 review S1)

    /// The round buffer, read through reflection (the property is private).
    private func buffered(_ fetch: ZeppHistoryFetch) -> [UInt8]? {
        Mirror(reflecting: fetch).children.first { $0.label == "buffer" }?.value as? [UInt8]
    }

    func testAnnouncedLengthOverTheCapFailsTheRoundBeforeAnyDataIsBuffered() {
        // The review probe: a start reply announcing ff ff ff ff, then 1 MiB of data.
        let now = date(1_790_700_000)
        var fetch = ZeppHistoryFetch(plan: [(.autoStress, now.addingTimeInterval(-3_600))], now: now,
                                     configuration: .init(ackPolicy: .deleteAfterDurableCommit, timeZone: utc))
        _ = fetch.start()
        var reply: [UInt8] = [0x10, 0x01, 0x01] + le32(0xFFFF_FFFF)
        reply += ZeppFetchTimestamp.encode(now.addingTimeInterval(-3_600), timeZone: utc)
        reply.append(0x00)
        XCTAssertEqual(fetch.receiveControl(reply), [
            .roundFailed(type: .autoStress, failure: .announcedLengthTooLarge(announced: 0xFFFF_FFFF, limit: 4 << 20)),
            .sendControl(hex("03 09")),
        ])
        XCTAssertEqual(fetch.phase, .awaitingAckReply)
        let packet = [UInt8](repeating: 0x20, count: 512)
        var counter: UInt8 = 0
        for _ in 0..<(1024 * 1024 / 512) {
            XCTAssertEqual(fetch.receiveData([counter] + packet), [])
            counter &+= 1
        }
        XCTAssertEqual(buffered(fetch), [])
        XCTAssertEqual(fetch.phase, .awaitingAckReply)
    }

    func testActivityCapCountsRecordsTimesEight() {
        // ff ff ff ff activity records would be about 34 GB.
        var fetch = machine([(.activity, sinceD)])
        _ = fetch.start()
        XCTAssertEqual(fetch.receiveControl(activityStart(0xFFFF_FFFF, at: hex("ea 07 09 1d 00 00 00 08"))), [
            .roundFailed(type: .activity, failure: .announcedLengthTooLarge(announced: 0xFFFF_FFFF * 8, limit: 4 << 20)),
            .sendControl(hex("03 09")),
        ])
        // 524,288 records are exactly 4 MiB and still accepted; one more record is not.
        var atCap = machine([(.activity, sinceD)])
        _ = atCap.start()
        XCTAssertEqual(atCap.receiveControl(activityStart(524_288, at: hex("ea 07 09 1d 00 00 00 08"))),
                       [.sendControl([0x02])])
        var overCap = machine([(.activity, sinceD)])
        _ = overCap.start()
        XCTAssertEqual(overCap.receiveControl(activityStart(524_289, at: hex("ea 07 09 1d 00 00 00 08"))), [
            .roundFailed(type: .activity, failure: .announcedLengthTooLarge(announced: 4_194_312, limit: 4 << 20)),
            .sendControl(hex("03 09")),
        ])
    }

    func testCapIsConfigurableAndInclusive() {
        // Worked example D announces 12 bytes.
        var atLimit = ZeppHistoryFetch(plan: [(.hrv, sinceD)], now: date(1_790_633_430),
                                       configuration: .init(timeZone: plusTwo, maxRoundBytes: 12))
        _ = atLimit.start()
        XCTAssertEqual(atLimit.receiveControl(startReplyD), [.sendControl([0x02])])
        var belowLimit = ZeppHistoryFetch(plan: [(.hrv, sinceD)], now: date(1_790_633_430),
                                          configuration: .init(timeZone: plusTwo, maxRoundBytes: 11))
        _ = belowLimit.start()
        XCTAssertEqual(belowLimit.receiveControl(startReplyD), [
            .roundFailed(type: .hrv, failure: .announcedLengthTooLarge(announced: 12, limit: 11)),
            .sendControl(hex("03 09")),
        ])
        // Like every failed round, it is retried once from the same since.
        XCTAssertEqual(belowLimit.receiveControl(hex("10 03 01")), [.sendControl(hex("01 49 ea 07 09 1d 00 00 00 08"))])
        XCTAssertEqual(ZeppHistoryFetch.Configuration().maxRoundBytes, 4_194_304)
    }

    func testHundredDayActivityBacklogIsAccepted() throws {
        // 100 days × 1440 minutes = 144,000 records = 1,152,000 B, the default first-ever cursor's
        // worth of activity. Made-up minutes, delivered in 4000-byte packets with a CRC.
        let records = 144_000
        let minute = hex("01 10 02 46 00 00 00 00")
        var data = [UInt8]()
        data.reserveCapacity(records * 8)
        for _ in 0..<records { data += minute }
        var fetch = machine([(.activity, sinceD)], now: date(1_800_000_000))
        _ = fetch.start()
        XCTAssertEqual(fetch.receiveControl(activityStart(records, at: hex("ea 07 09 1d 00 00 00 08"))),
                       [.sendControl([0x02])])
        var counter: UInt8 = 0
        var offset = 0
        while offset < data.count {
            let end = min(offset + 4000, data.count)
            XCTAssertEqual(fetch.receiveData([counter] + data[offset..<end]), [])
            counter &+= 1
            offset = end
        }
        let round = try XCTUnwrap(readyRound(fetch.receiveControl([0x10, 0x02, 0x01] + le32(ZeppCRC32.checksum(data)))))
        XCTAssertTrue(round.crcVerified)
        XCTAssertEqual(round.rawData.count, 1_152_000)
        XCTAssertEqual(round.parsed.records.count, records)
        XCTAssertEqual(round.nextSince, date(1_790_632_800 + TimeInterval(records * 60)))
    }

    func testAnnouncedLengthTooLargeDescription() {
        XCTAssertEqual(ZeppRoundFailure.announcedLengthTooLarge(announced: 34_359_738_360, limit: 4_194_304).description,
                       "announced length too large, announced 34359738360 B, limit 4194304 B")
    }
}
