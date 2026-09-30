// History fetch (ZEPP_PROTOCOL.md §6) as a pure state machine with an explicit ack policy.
//
// THE ACK IS THE ONLY DESTRUCTIVE THING IN THIS PROTOCOL. `03 01` tells the strap the data is saved
// on the phone and it stops offering it; `03 09` acknowledges but keeps it (§6.3). This machine
// sends `03 09` on EVERY path except one: the policy is `.deleteAfterDurableCommit` AND the round's
// transfer done carried a CRC that matched AND the caller has called `commit(roundID:durable: true)`
// for that exact round after persisting it. Failures, rounds without a CRC, empty rounds, aborts
// and the default policy all keep the data on the strap.
//
// Path-agnostic: control bytes are identical on Path A (`…0004`) and Path B (endpoint 0x004B,
// §6.1). The caller routes `.sendControl` payloads and feeds control replies to
// `receiveControl`, data notifications (`…0005`) to `receiveData`.

import Foundation

public enum ZeppAckPolicy: Equatable {
    /// Always `03 09`: the strap keeps everything (development default, §6.3).
    case keepOnDevice
    /// `03 01` only for a CRC-verified round the caller confirmed as durably committed; `03 09`
    /// otherwise.
    case deleteAfterDurableCommit
}

public enum ZeppAckMode: UInt8, Equatable {
    /// "Saved on the phone": the strap stops offering the data.
    case delete = 0x01
    /// Acknowledged but kept on the strap (non-destructive).
    case keep = 0x09
}

public enum ZeppFetchCommand {
    public static let startMarker: UInt8 = 0x01
    public static let fetchData: [UInt8] = [0x02]
    public static let ackMarker: UInt8 = 0x03

    /// `01 <type> <since: 8 bytes>` (§6.2).
    public static func start(_ type: ZeppFetchType, since: Date, timeZone: TimeZone) -> [UInt8] {
        [startMarker, type.rawValue] + ZeppFetchTimestamp.encode(since, timeZone: timeZone)
    }

    public static func ack(_ mode: ZeppAckMode) -> [UInt8] {
        [ackMarker, mode.rawValue]
    }
}

/// Why a round was not delivered. Every one of these ends in `03 09` (keep) or no ack at all.
public enum ZeppRoundFailure: Equatable {
    /// `10 01 <status ≠ 01>`: type unsupported or refused. No round was opened; nothing is acked.
    case startRefused(status: UInt8)
    /// The start reply was not 15 or 16 bytes, or it announced data with an invalid timestamp.
    case malformedStartReply
    /// The start reply announced more bytes (length × the type's unit) than
    /// `Configuration.maxRoundBytes` allows. Rejected before any data is buffered.
    case announcedLengthTooLarge(announced: Int, limit: Int)
    /// A data packet counter was skipped or repeated (§9 #9).
    case packetCounterGap(expected: UInt8, got: UInt8)
    /// More data than the start reply announced. Both counts are bytes: for activity, `expected`
    /// is the announced record count × 8.
    case dataOverflow(expected: Int, received: Int)
    /// Transfer done with less (or more) data than announced, in bytes as for `dataOverflow`.
    case lengthMismatch(expected: Int, received: Int)
    /// `10 02 <status ≠ 01>`.
    case transferFailed(status: UInt8)
    /// The transfer-done reply was neither 3 nor 7 bytes.
    case malformedTransferDone
    /// The transfer-done CRC-32 did not match the data.
    case crcMismatch(expected: UInt32, computed: UInt32)
    case parseFailed(ZeppRecordParser.Error)
    /// The caller aborted mid-round.
    case aborted
}

extension ZeppRoundFailure: CustomStringConvertible {
    /// For logs: lengths in bytes, CRCs in hex (the announced one first).
    public var description: String {
        switch self {
        case .startRefused(let status): return String(format: "start refused, status %02x", status)
        case .malformedStartReply: return "malformed start reply"
        case .announcedLengthTooLarge(let announced, let limit):
            return "announced length too large, announced \(announced) B, limit \(limit) B"
        case .packetCounterGap(let expected, let got):
            return String(format: "packet counter gap, expected %02x, got %02x", expected, got)
        case .dataOverflow(let expected, let received):
            return "data overflow, announced \(expected) B, received \(received) B"
        case .lengthMismatch(let expected, let received):
            return "length mismatch, announced \(expected) B, received \(received) B"
        case .transferFailed(let status): return String(format: "transfer failed, status %02x", status)
        case .malformedTransferDone: return "malformed transfer-done reply"
        case .crcMismatch(let expected, let computed):
            return String(format: "CRC mismatch, announced 0x%08x, computed 0x%08x", expected, computed)
        case .parseFailed(let error): return "parse failed, \(error)"
        case .aborted: return "aborted"
        }
    }
}

/// One successfully fetched and parsed round, awaiting the caller's commit decision.
public struct ZeppFetchRound: Equatable {
    /// Pass this back to `commit(roundID:durable:)`.
    public let id: Int
    public let type: ZeppFetchType
    public let since: Date
    /// First-record time from the start reply.
    public let start: Date
    /// The round's concatenated data exactly as received (counters stripped). Keep it with the
    /// parsed records if the store should be able to re-decode later.
    public let rawData: [UInt8]
    /// true when the transfer-done reply carried a CRC and it matched; false when it carried none.
    /// Only a CRC-verified round can be delete-acked (`03 01`).
    public let crcVerified: Bool
    public let parsed: ZeppParsedRecords
    /// The *since* the next round of this type will use (last record + 1 minute); nil when the
    /// round held no records. Persist it as the type's cursor only after a durable commit.
    public let nextSince: Date?
}

public struct ZeppHistoryFetch {

    public enum Action: Equatable {
        /// Write these bytes as a control command (Path A: `…0004`; Path B: endpoint 0x004B).
        case sendControl([UInt8])
        /// A parsed round. Persist it, then call `commit(roundID:durable:)`.
        case roundReady(ZeppFetchRound)
        case roundFailed(type: ZeppFetchType, failure: ZeppRoundFailure)
        /// The strap had nothing for this type since the cursor (expected length 0, whatever the
        /// start timestamp). The type is done for this fetch.
        case noData(type: ZeppFetchType)
        /// Every type in the plan is done.
        case finished
    }

    public enum Phase: Equatable {
        case idle
        case awaitingStartReply
        case receivingData
        case awaitingCommit
        case awaitingAckReply
        case finished
    }

    public struct Configuration: Equatable {
        public var ackPolicy: ZeppAckPolicy = .keepOnDevice
        /// Upper bound on rounds per type (§6.4: Gadgetbridge ~11, HelioCore 20).
        public var maxRoundsPerType = 11
        /// A failed round of a type is retried this many times from the same *since* (§9 #9).
        /// SPEC-GAP: §9 says "retry" without a count; one retry, then the type is left for next time.
        public var maxRetriesPerType = 1
        public var timeZone: TimeZone = .current
        /// Upper bound on one round's announced size in bytes (length × the type's unit). The strap
        /// controls the announced length (any u32), and the round is buffered in memory, so a larger
        /// announcement fails the round before any data is kept. 4 MiB is well above the largest
        /// real round: a 100-day activity backlog is 144,000 records × 8 B = 1,152,000 B, and the
        /// real 12 h activity round was 5760 B (§10.1).
        public var maxRoundBytes = 4 << 20

        public init(ackPolicy: ZeppAckPolicy = .keepOnDevice, maxRoundsPerType: Int = 11,
                    maxRetriesPerType: Int = 1, timeZone: TimeZone = .current, maxRoundBytes: Int = 4 << 20) {
            self.ackPolicy = ackPolicy
            self.maxRoundsPerType = maxRoundsPerType
            self.maxRetriesPerType = maxRetriesPerType
            self.timeZone = timeZone
            self.maxRoundBytes = maxRoundBytes
        }
    }

    public private(set) var phase: Phase = .idle
    public let configuration: Configuration
    private let now: Date
    private var queue: [(type: ZeppFetchType, since: Date)]
    private var current: (type: ZeppFetchType, since: Date)?
    private var roundsThisType = 0
    private var retriesThisType = 0
    private var nextRoundID = 1

    // Per-round state.
    private var expectedLength = 0
    private var roundStart = Date(timeIntervalSince1970: 0)
    private var buffer: [UInt8] = []
    private var nextCounter: UInt8 = 0
    private var pendingRound: ZeppFetchRound?
    /// What to do once the ack reply arrives: continue from this *since*, retry, or move on.
    private var afterAck: AfterAck = .nextType

    private enum AfterAck: Equatable {
        case nextRound(since: Date)
        case retry
        case nextType
    }

    /// - Parameters:
    ///   - plan: types to fetch, each from its cursor (the *since* of its first round).
    ///   - now: rounds never ask for a *since* after this.
    public init(plan: [(type: ZeppFetchType, since: Date)], now: Date, configuration: Configuration = Configuration()) {
        self.queue = plan
        self.now = now
        self.configuration = configuration
    }

    /// Default first-ever cursor: 100 days back (§6.4).
    public static func defaultInitialCursor(now: Date) -> Date {
        now.addingTimeInterval(-100 * 86_400)
    }

    public mutating func start() -> [Action] {
        guard phase == .idle else { return [] }
        return beginNextType()
    }

    // MARK: Inputs

    /// A control reply from the strap (`…0004` notification or an endpoint-0x004B message).
    public mutating func receiveControl(_ bytes: [UInt8]) -> [Action] {
        guard bytes.count >= 2, bytes[0] == 0x10 else { return [] }
        switch (phase, bytes[1]) {
        case (.awaitingStartReply, 0x01):
            return handleStartReply(bytes)
        case (.receivingData, 0x02):
            return handleTransferDone(bytes)
        case (.awaitingAckReply, 0x03):
            // SPEC-GAP: the ack reply's status byte is unexplained (§6.2 🔴); any `10 03` ends the round.
            return afterAckReply()
        default:
            return []
        }
    }

    /// A `…0005` data notification: counter byte, then data.
    public mutating func receiveData(_ bytes: [UInt8]) -> [Action] {
        guard phase == .receivingData, let counter = bytes.first, let type = current?.type else { return [] }
        guard counter == nextCounter else {
            return failRound(type, .packetCounterGap(expected: nextCounter, got: counter))
        }
        nextCounter &+= 1
        buffer += bytes.dropFirst()
        guard buffer.count <= expectedLength else {
            return failRound(type, .dataOverflow(expected: expectedLength, received: buffer.count))
        }
        return []
    }

    /// The caller's decision for a delivered round. `durable: true` means the round's records are
    /// persisted and will survive a crash; only then, only under `.deleteAfterDurableCommit`, and
    /// only for a round whose CRC was checked (`crcVerified`), does the strap get `03 01`. Anything
    /// else is `03 09`.
    public mutating func commit(roundID: Int, durable: Bool) -> [Action] {
        guard phase == .awaitingCommit, let round = pendingRound, round.id == roundID else { return [] }
        pendingRound = nil
        // A 3-byte transfer done has no CRC, so nothing proves the data arrived intact: keep it.
        // The Helio always sent the 7-byte form (§10.1), so this costs nothing there.
        let deletable = durable && round.crcVerified && configuration.ackPolicy == .deleteAfterDurableCommit
        let mode: ZeppAckMode = deletable ? .delete : .keep
        if let next = round.nextSince, next.timeIntervalSince(round.since) >= 1, next <= now {
            afterAck = .nextRound(since: next)
        } else {
            afterAck = .nextType
        }
        phase = .awaitingAckReply
        return [.sendControl(ZeppFetchCommand.ack(mode))]
    }

    /// Stops the fetch. A round in progress is acked with `03 09` (keep) so the strap is not left
    /// mid-transfer; nothing is ever deleted by an abort.
    public mutating func abort() -> [Action] {
        var out = [Action]()
        switch phase {
        case .receivingData, .awaitingCommit:
            if let type = current?.type { out.append(.roundFailed(type: type, failure: .aborted)) }
            out.append(.sendControl(ZeppFetchCommand.ack(.keep)))
        default:
            break
        }
        pendingRound = nil
        queue.removeAll()
        current = nil
        phase = .finished
        return out
    }

    // MARK: Round steps

    private mutating func handleStartReply(_ bytes: [UInt8]) -> [Action] {
        guard let type = current?.type else { return [] }
        guard bytes.count >= 3 else { return failRound(type, .malformedStartReply) }
        guard bytes[2] == 0x01 else {
            // Refused or unsupported: skip the type; no round was opened, so nothing is acked.
            // SPEC-GAP: the spec says "skip it" and names no ack for this case.
            return [.roundFailed(type: type, failure: .startRefused(status: bytes[2]))] + beginNextType()
        }
        var reader = ZeppByteReader(bytes, offset: 3)
        // The strap did open a round on every malformed path below; keep its data.
        guard bytes.count == 15 || bytes.count == 16, let length = reader.u32() else {
            return failRound(type, .malformedStartReply)
        }
        buffer = []
        nextCounter = 0
        // Length 0 is an empty round whatever the start timestamp says (§6.2): the strap pairs it
        // with a far-future sentinel or with all zeros, which is not a valid timestamp.
        if length == 0 {
            expectedLength = 0
            afterAck = .nextType
            phase = .awaitingAckReply
            return [.noData(type: type), .sendControl(ZeppFetchCommand.ack(.keep))]
        }
        // Checked in bytes from here on: activity announces records (§6.2). The cap bounds the
        // memory a strap can make us hold for one round; the round is kept on the strap.
        let (announced, overflow) = Int(length).multipliedReportingOverflow(by: type.startReplyLengthUnit)
        guard !overflow, announced <= configuration.maxRoundBytes else {
            return failRound(type, .announcedLengthTooLarge(announced: overflow ? .max : announced,
                                                            limit: configuration.maxRoundBytes))
        }
        guard let start = ZeppFetchTimestamp.decode(bytes[7..<15]) else {
            return failRound(type, .malformedStartReply)
        }
        roundStart = start
        expectedLength = announced
        phase = .receivingData
        return [.sendControl(ZeppFetchCommand.fetchData)]
    }

    private mutating func handleTransferDone(_ bytes: [UInt8]) -> [Action] {
        guard let current else { return [] }
        let type = current.type
        guard bytes.count >= 3 else { return failRound(type, .malformedTransferDone) }
        guard bytes[2] == 0x01 else { return failRound(type, .transferFailed(status: bytes[2])) }
        guard bytes.count == 3 || bytes.count == 7 else { return failRound(type, .malformedTransferDone) }
        // A length other than the announced one rejects the round (§6.5, in bytes); like every
        // invalid round it is kept on the strap and retried (retry count: see Configuration).
        guard buffer.count == expectedLength else {
            return failRound(type, .lengthMismatch(expected: expectedLength, received: buffer.count))
        }
        var crcVerified = false
        if bytes.count == 7 {
            var reader = ZeppByteReader(bytes, offset: 3)
            let expected = reader.u32() ?? 0
            let computed = ZeppCRC32.checksum(buffer)
            // Checked for every type. Gadgetbridge skips the check for activity (0x01) without saying
            // why, but on the Helio the activity CRC matches like every other type's: 60 records
            // (480 B) and a full 12 h round of 720 records (5760 B) (§6.5, §10.1, HW 2026-09-30
            // 13:35). A mismatch keeps the data on the strap, and the failure carries the
            // announced and the computed CRC.
            guard expected == computed else {
                return failRound(type, .crcMismatch(expected: expected, computed: computed))
            }
            crcVerified = true
        }
        let parsed: ZeppParsedRecords
        do {
            parsed = try ZeppRecordParser.parse(type, data: buffer, start: roundStart)
        } catch let error as ZeppRecordParser.Error {
            return failRound(type, .parseFailed(error))
        } catch {
            return failRound(type, .malformedTransferDone)
        }
        let round = ZeppFetchRound(id: nextRoundID, type: type, since: current.since, start: roundStart,
                                   rawData: buffer, crcVerified: crcVerified, parsed: parsed,
                                   nextSince: parsed.lastRecordTime?.addingTimeInterval(60))
        nextRoundID += 1
        roundsThisType += 1
        buffer = []
        pendingRound = round
        phase = .awaitingCommit
        return [.roundReady(round)]
    }

    private mutating func afterAckReply() -> [Action] {
        switch afterAck {
        case .nextRound(let since) where roundsThisType < configuration.maxRoundsPerType:
            guard let type = current?.type else { return beginNextType() }
            return beginRound(type, since: since)
        case .retry where retriesThisType < configuration.maxRetriesPerType:
            guard let current else { return beginNextType() }
            retriesThisType += 1
            return beginRound(current.type, since: current.since)
        default:
            return beginNextType()
        }
    }

    /// Any failure after the strap opened a round: ack `03 09` (keep) and retry after the reply.
    private mutating func failRound(_ type: ZeppFetchType, _ failure: ZeppRoundFailure) -> [Action] {
        buffer = []
        afterAck = .retry
        phase = .awaitingAckReply
        return [.roundFailed(type: type, failure: failure), .sendControl(ZeppFetchCommand.ack(.keep))]
    }

    private mutating func beginNextType() -> [Action] {
        guard !queue.isEmpty else {
            current = nil
            phase = .finished
            return [.finished]
        }
        let next = queue.removeFirst()
        roundsThisType = 0
        retriesThisType = 0
        return beginRound(next.type, since: next.since)
    }

    private mutating func beginRound(_ type: ZeppFetchType, since: Date) -> [Action] {
        current = (type, since)
        phase = .awaitingStartReply
        return [.sendControl(ZeppFetchCommand.start(type, since: since, timeZone: configuration.timeZone))]
    }
}
