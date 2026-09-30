// A simulated strap, written from ZEPP_PROTOCOL.md for the tests. Its chunk parsing, chunk
// building, message encryption and session derivation are implemented HERE, independently of
// ZeppKit's transport, so a phone ⇄ device run checks the two sides against the spec rather than
// against themselves. It reuses only the primitives that have their own oracles: B163 (OpenSSL
// vectors), ZeppAES (NIST vectors) and ZeppCRC32 (check value).

import Foundation
@testable import ZeppKit

final class FakeZeppDevice {

    struct Notification: Equatable {
        let characteristic: ZeppCharacteristic
        let bytes: [UInt8]
    }

    // Configuration
    let authKey: [UInt8]
    let privateKey: [UInt8]
    let random: [UInt8]
    var writeLength: Int
    var services: [(endpoint: UInt16, flag: UInt8)] = [
        (0x0000, 0), (0x000A, 1), (0x0029, 1), (0x0043, 0), (0x0047, 0), (0x004B, 1), (0x0082, 0),
    ]
    var batteryReply = hex("04 00 57 01 00 00 00 00 00 00 00 ea 07 09 1d 08 00 00 08 00 64")
    var configReply: [UInt8] = hex("04 01 08 03 00 02 01 10 ff 13 0b 00")
    /// Fetch data per type: the start reply's first-record time bytes (8) and the data.
    var fetchData: [ZeppFetchType: (start: [UInt8], data: [UInt8])] = [:]
    /// Data packet size (counter byte included).
    var dataPacketLength = 20
    var includeCRC = true
    var corruptCRC = false
    var skipPacketIndex: Int?
    var refuseTypes: Set<ZeppFetchType> = []

    // Device controls (§11–§13). Only reachable when a test lists their endpoints in `services`.
    /// The find-device capabilities reply (§11.2); nil = the strap never answers `01`.
    var findCapabilitiesReply: [UInt8]? = hex("02 01 02")
    /// Alarm slot → the 10-byte record as the strap returns it (byte [8] = 01, §12.3).
    var alarmRecords: [UInt8: [UInt8]] = [:]
    /// Status byte of the alarm create/delete acks; anything but 01 leaves the alarms unchanged.
    var alarmAckStatus: UInt8 = 0x01
    /// Send `0f` (alarms changed) after each accepted alarm write.
    var announcesAlarmChanges = false
    var configCapabilitiesReply = hex("02 03 01 08")
    /// Config read replies by exact request payload; any other read gets `configReply`.
    var configReplies: [[UInt8]: [UInt8]] = [:]

    // Observed state
    private(set) var sessionKey: [UInt8]?
    private(set) var authenticated = false
    private(set) var receivedAcks: [[UInt8]] = []
    private(set) var receivedEndpoints: [UInt16] = []
    private(set) var fetchAcks: [UInt8] = []
    private(set) var fetchStarts: [[UInt8]] = []
    private(set) var failures: [String] = []
    /// Opcodes received on the find-device endpoint, in order.
    private(set) var findOpcodes: [UInt8] = []
    private(set) var isBuzzing = false
    /// Every payload received on the alarms endpoint, in order.
    private(set) var alarmCommands: [[UInt8]] = []
    private(set) var timeSetCount = 0
    private(set) var configWrites: [[UInt8]] = []

    private var expectedPhoneSequence: UInt32 = 0
    private var deviceSequence: UInt32 = 0
    private var outgoingHandle: UInt8 = 0
    private var inbox: (endpoint: UInt16, handle: UInt8, encrypted: Bool, declared: Int, body: [UInt8], next: Int)?
    private var currentFetch: ZeppFetchType?

    init(authKey: [UInt8], privateKey: [UInt8], random: [UInt8], writeLength: Int = 20) {
        self.authKey = authKey
        self.privateKey = privateKey
        self.random = random
        self.writeLength = writeLength
    }

    var publicKey: [UInt8] { try! B163.publicKey(forPrivateKey: privateKey) }

    // MARK: Phone → device

    func phoneWrote(_ write: ZeppWrite) -> [Notification] {
        switch write.characteristic {
        case .chunkedWrite: return receiveChunk(write.bytes)
        case .chunkedRead:
            receivedAcks.append(write.bytes)
            return []
        case .activityControl: return fetchControl(write.bytes)
        default:
            failures.append("write to \(write.characteristic)")
            return []
        }
    }

    private func receiveChunk(_ c: [UInt8]) -> [Notification] {
        guard c.count >= 5, c[0] == 0x03 else { failures.append("not a chunk"); return [] }
        let flags = c[1], handle = c[3], index = Int(c[4])
        if flags & 0x01 != 0 {
            guard c.count >= 11, index == 0 else { failures.append("bad first chunk"); return [] }
            let declared = Int(readLE32(c, 5))
            let endpoint = UInt16(c[9]) | (UInt16(c[10]) << 8)
            inbox = (endpoint, handle, flags & 0x08 != 0, declared, Array(c[11...]), 1)
        } else {
            guard var m = inbox, m.handle == handle, m.next == index else { failures.append("bad continuation"); return [] }
            m.body += c[5...]
            m.next += 1
            inbox = m
        }
        guard flags & 0x02 != 0, let m = inbox else { return [] }
        inbox = nil
        guard flags & 0x04 != 0 else { failures.append("last chunk without ack request"); return [] }
        var payload = m.body
        if m.encrypted {
            guard let key = sessionKey, m.body.count % 16 == 0 else { failures.append("cannot decrypt"); return [] }
            let plain = try! ZeppAES.decryptECB(key: key.map { $0 ^ handle }, m.body)
            payload = Array(plain[0..<m.declared])
            // The device checks the phone's trailer: S = its expected sequence, C = CRC32(P ‖ S).
            let s = readLE32(plain, m.declared)
            let crc = readLE32(plain, m.declared + 4)
            if s != expectedPhoneSequence { failures.append("phone sequence \(s) != \(expectedPhoneSequence)") }
            if crc != ZeppCRC32.checksum(plain[0..<(m.declared + 4)]) { failures.append("phone CRC wrong") }
            if plain[(m.declared + 8)...].contains(where: { $0 != 0 }) { failures.append("non-zero padding") }
            expectedPhoneSequence &+= 1
        } else if payload.count != m.declared {
            failures.append("plaintext length mismatch")
            return []
        }
        receivedEndpoints.append(m.endpoint)
        return handleMessage(endpoint: m.endpoint, payload)
    }

    private func handleMessage(endpoint: UInt16, _ p: [UInt8]) -> [Notification] {
        switch endpoint {
        case 0x0082 where p.first == 0x04:
            guard p.count == 52, Array(p[1..<4]) == [0x02, 0x00, 0x02] else { failures.append("bad 04"); return [] }
            let shared = try! B163.sharedSecret(privateKey: privateKey, peerPublicKey: Array(p[4...]))
            sessionKey = (0..<16).map { shared[8 + $0] ^ authKey[$0] }
            let seed = readLE32(shared, 0)
            expectedPhoneSequence = seed
            deviceSequence = seed
            return send(endpoint: 0x0082, [0x10, 0x04, 0x01] + random + publicKey)
        case 0x0082 where p.first == 0x05:
            guard p.count == 33, let key = sessionKey else { failures.append("bad 05"); return [] }
            let ok = Array(p[1..<17]) == (try! ZeppAES.encryptECB(key: authKey, random))
                && Array(p[17..<33]) == (try! ZeppAES.encryptECB(key: key, random))
            authenticated = ok
            return send(endpoint: 0x0082, [0x10, 0x05, ok ? 0x01 : 0x25])
        case 0x0000 where p == [0x03]:
            var reply: [UInt8] = [0x04, UInt8(services.count), 0x00]
            for s in services { reply += [UInt8(s.endpoint & 0xFF), UInt8(s.endpoint >> 8), s.flag] }
            return send(endpoint: 0x0000, reply)
        case 0x0029 where p == [0x03]:
            return send(endpoint: 0x0029, batteryReply)
        case 0x000A where p.first == 0x03:
            return send(endpoint: 0x000A, configReplies[p] ?? configReply)
        case 0x000A where p == [0x01]:
            return send(endpoint: 0x000A, configCapabilitiesReply)
        case 0x000A where p.first == 0x05:
            configWrites.append(p)
            return send(endpoint: 0x000A, [0x06, 0x01])
        case 0x0047 where p.first == 0x05:
            guard p.count == 12 else { failures.append("bad time set"); return [] }
            timeSetCount += 1
            return send(endpoint: 0x0047, [0x06, 0x01])
        case 0x001A:
            return findDevice(p)
        case 0x000F:
            return alarms(p)
        default:
            failures.append("unhandled message on \(endpoint)")
            return []
        }
    }

    // MARK: Device controls (§11, §12)

    private func findDevice(_ p: [UInt8]) -> [Notification] {
        guard let opcode = p.first, p.count == 1 || p == [0x12, 0x01] else {
            failures.append("bad find-device payload \(p)")
            return []
        }
        findOpcodes.append(opcode)
        switch opcode {
        case 0x01: return findCapabilitiesReply.map { send(endpoint: 0x001A, $0) } ?? []
        case 0x03:
            isBuzzing = true
            return send(endpoint: 0x001A, [0x04])
        case 0x06:
            isBuzzing = false
            return []
        case 0x12, 0x14: return []
        default:
            failures.append("find-device opcode \(opcode) is never sent by a phone")
            return []
        }
    }

    private func alarms(_ p: [UInt8]) -> [Notification] {
        alarmCommands.append(p)
        var out = [Notification]()
        switch p.first {
        case 0x09 where p.count == 1:
            var reply: [UInt8] = [0x0a, UInt8(alarmRecords.count)]
            for slot in alarmRecords.keys.sorted() { reply += alarmRecords[slot]! }
            return send(endpoint: 0x000F, reply)
        case 0x03 where p.count == 12 && p[1] == 0x01:
            var record = Array(p[2...])
            guard record[1] < 10 else { failures.append("alarm slot \(record[1])"); return [] }
            record[8] = 0x01
            if alarmAckStatus == 0x01 { alarmRecords[record[1]] = record }
            out = send(endpoint: 0x000F, [0x04, alarmAckStatus])
        case 0x05 where p.count == 3 && p[1] == 0x01:
            if alarmAckStatus == 0x01 { alarmRecords[p[2]] = nil }
            out = send(endpoint: 0x000F, [0x06, alarmAckStatus])
        default:
            failures.append("alarm command \(p) is never sent by ZeppKit")
            return []
        }
        if announcesAlarmChanges && alarmAckStatus == 0x01 { out += send(endpoint: 0x000F, [0x0f]) }
        return out
    }

    /// A strap-originated message (find device `07`, find phone `11`, alarms changed `0f`, …).
    func unsolicited(endpoint: UInt16, _ payload: [UInt8]) -> [Notification] {
        send(endpoint: endpoint, payload)
    }

    // MARK: Device → phone

    private func isEncrypted(_ endpoint: UInt16) -> Bool {
        authenticated && services.first { $0.endpoint == endpoint }?.flag == 1
    }

    private func send(endpoint: UInt16, _ payload: [UInt8]) -> [Notification] {
        outgoingHandle &+= 1
        let handle = outgoingHandle
        let encrypted = isEncrypted(endpoint)
        var body = payload
        if encrypted, let key = sessionKey {
            var buffer = payload + le32(deviceSequence)
            buffer += le32(ZeppCRC32.checksum(buffer))
            while buffer.count % 16 != 0 { buffer.append(0) }
            body = try! ZeppAES.encryptECB(key: key.map { $0 ^ handle }, buffer)
            deviceSequence &+= 1
        }
        var out = [Notification]()
        var offset = 0
        var index = 0
        repeat {
            let first = index == 0
            let room = writeLength - (first ? 11 : 5)
            let take = min(room, body.count - offset)
            let last = offset + take == body.count
            let flags: UInt8 = (first ? 0x01 : 0) | (last ? 0x06 : 0) | (encrypted ? 0x08 : 0)
            var chunk: [UInt8] = [0x03, flags, 0x00, handle, UInt8(index)]
            if first { chunk += le32(UInt32(payload.count)) + le16(endpoint) }
            chunk += body[offset..<(offset + take)]
            out.append(Notification(characteristic: .chunkedRead, bytes: chunk))
            offset += take
            index += 1
        } while offset < body.count
        return out
    }

    // MARK: History fetch, Path A

    private func fetchControl(_ c: [UInt8]) -> [Notification] {
        func control(_ bytes: [UInt8]) -> Notification { Notification(characteristic: .activityControl, bytes: bytes) }
        switch c.first {
        case 0x01:
            fetchStarts.append(c)
            guard c.count == 10, let type = ZeppFetchType(rawValue: c[1]) else { return [control([0x10, 0x01, 0x02])] }
            if refuseTypes.contains(type) { return [control([0x10, 0x01, 0x04])] }
            currentFetch = type
            let entry = fetchData[type] ?? (start: Array(c[2..<10]), data: [])
            return [control([0x10, 0x01, 0x01] + le32(UInt32(entry.data.count)) + entry.start)]
        case 0x02:
            guard let type = currentFetch else { return [] }
            let data = fetchData[type]?.data ?? []
            var out = [Notification]()
            var counter: UInt8 = 0
            var index = 0
            var offset = 0
            while offset < data.count {
                let take = min(dataPacketLength - 1, data.count - offset)
                if index != skipPacketIndex {
                    out.append(Notification(characteristic: .activityData, bytes: [counter] + data[offset..<(offset + take)]))
                }
                counter &+= 1
                index += 1
                offset += take
            }
            var crc = ZeppCRC32.checksum(data)
            if corruptCRC { crc ^= 1 }
            out.append(control([0x10, 0x02, 0x01] + (includeCRC ? le32(crc) : [])))
            return out
        case 0x03:
            guard c.count == 2 else { return [] }
            fetchAcks.append(c[1])
            currentFetch = nil
            return [control([0x10, 0x03, 0x01])]
        default:
            return []
        }
    }
}

/// Shuttles bytes between a `ZeppLink` and a `FakeZeppDevice` until nothing more happens.
func pump(_ link: inout ZeppLink, _ device: FakeZeppDevice, _ writes: [ZeppWrite]) -> [ZeppLink.Event] {
    var pending = writes
    var events = [ZeppLink.Event]()
    var guardCount = 0
    while !pending.isEmpty, guardCount < 10_000 {
        guardCount += 1
        let write = pending.removeFirst()
        for n in device.phoneWrote(write) where n.characteristic == .chunkedRead || n.characteristic == .chunkedWrite {
            let out = link.receive(n.bytes)
            pending += out.writes
            events += out.events
        }
    }
    return events
}
