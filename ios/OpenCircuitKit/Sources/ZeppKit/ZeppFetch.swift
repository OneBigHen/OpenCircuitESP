// History fetch (ZEPP_PROTOCOL.md §6) as a pure state machine with an explicit ack policy.
//
// THE ACK IS THE ONLY DESTRUCTIVE THING IN THIS PROTOCOL. `03 01` tells the strap the data is saved
// on the phone and it stops offering it; `03 09` acknowledges but keeps it (§6.3). This machine
// sends `03 09` on EVERY path except one: the policy is `.deleteAfterDurableCommit` AND the caller
// has called `commit(roundID:durable: true)` for that exact round after persisting it. Failures,
// empty rounds, aborts and the default policy all keep the data on the strap.
//
// Path-agnostic: control bytes are identical on Path A (`…0004`) and Path B (endpoint 0x004B,
// §6.1). The caller routes `.sendControl` payloads and feeds control replies to
// `receiveControl`, data notifications (`…0005`) to `receiveData`.

import Foundation

public enum ZeppAckPolicy: Equatable {
    /// Always `03 09`: the strap keeps everything (development default, §6.3).
    case keepOnDevice
    /// `03 01` only for a round the caller confirmed as durably committed; `03 09` otherwise.
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
    /// The start reply was not 15 or 16 bytes, or its timestamp was invalid.
    case malformedStartReply
    /// A data packet counter was skipped or repeated (§9 #9).
    case packetCounterGap(expected: UInt8, got: UInt8)
    /// More data than the start reply announced.
    case dataOverflow(expected: Int, received: Int)
    /// Transfer done with less (or more) data than announced.
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
        /// The strap had nothing for this type since the cursor (expected length 0).
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

        public init(ackPolicy: ZeppAckPolicy = .keepOnDevice, maxRoundsPerType: Int = 11,
                    maxRetriesPerType: Int = 1, timeZone: TimeZone = .current) {
            self.ackPolicy = ackPolicy
            self.maxRoundsPerType = maxRoundsPerType
            self.maxRetriesPerType = maxRetriesPerType
            self.timeZone = timeZone
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
    /// persisted and will survive a crash; only then, and only under `.deleteAfterDurableCommit`,
    /// does the strap get `03 01`. Anything else is `03 09`.
    public mutating func commit(roundID: Int, durable: Bool) -> [Action] {
        guard phase == .awaitingCommit, let round = pendingRound, round.id == roundID else { return [] }
        pendingRound = nil
        let mode: ZeppAckMode = (durable && configuration.ackPolicy == .deleteAfterDurableCommit) ? .delete : .keep
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
        guard bytes.count == 15 || bytes.count == 16,
              let length = reader.u32(),
              let start = ZeppFetchTimestamp.decode(bytes[7..<15]) else {
            // The strap did open a round; keep its data.
            return failRound(type, .malformedStartReply)
        }
        roundStart = start
        expectedLength = Int(length)
        buffer = []
        nextCounter = 0
        if expectedLength == 0 {
            afterAck = .nextType
            phase = .awaitingAckReply
            return [.noData(type: type), .sendControl(ZeppFetchCommand.ack(.keep))]
        }
        phase = .receivingData
        return [.sendControl(ZeppFetchCommand.fetchData)]
    }

    private mutating func handleTransferDone(_ bytes: [UInt8]) -> [Action] {
        guard let current else { return [] }
        let type = current.type
        guard bytes.count >= 3 else { return failRound(type, .malformedTransferDone) }
        guard bytes[2] == 0x01 else { return failRound(type, .transferFailed(status: bytes[2])) }
        guard bytes.count == 3 || bytes.count == 7 else { return failRound(type, .malformedTransferDone) }
        // SPEC-GAP: the spec does not say what to do when the data length differs from the
        // announced one. ZeppKit treats it as an invalid round (keep, retry).
        guard buffer.count == expectedLength else {
            return failRound(type, .lengthMismatch(expected: expectedLength, received: buffer.count))
        }
        var crcVerified = false
        if bytes.count == 7 {
            var reader = ZeppByteReader(bytes, offset: 3)
            let expected = reader.u32() ?? 0
            let computed = ZeppCRC32.checksum(buffer)
            // SPEC-GAP: Gadgetbridge skips the CRC check for activity (0x01) without saying why.
            // ZeppKit checks it for every type; a mismatch keeps the data on the strap.
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
