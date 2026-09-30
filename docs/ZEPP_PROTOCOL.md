# Zepp OS BLE protocol: Amazfit Helio Strap (living spec)

Facts-only specification of the Zepp OS ("Huami 2021") BLE protocol as used by the
**Amazfit Helio Strap**, written for a clean-room Swift implementation (#215). This is the
Phase-0 deliverable of the Helio plan: an implementer must be able to build the transport,
auth, session setup and history fetch **from this document alone**.

**Clean-room rules for this file.** It describes the protocol in prose, tables and byte
diagrams. It contains no code and no pseudo-code from the reference implementations, no
copied comments, and no identifiers except the protocol's own names (UUIDs, opcode values,
endpoint numbers). Every worked example was **constructed for this document** from made-up
keys and made-up readings; none is a capture or a fixture from another project.

Confidence legend (same as `PROTOCOL.md`): 🟢 confirmed on our own strap · 🟡 probable
(two sources agree, or one source that is known to work on the Helio) · 🔴 guess / single
source / inference. **Nothing here is 🟢 yet**: nothing has been checked on Juan's strap.
§10 is the checklist that promotes claims to 🟢.

## Source key

Citations use these aliases. Line numbers are 1-based at the pinned commit.

| Alias | What | Pin |
|---|---|---|
| `GB/` | Gadgetbridge (AGPL-3.0), path under `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/` | codeberg `Freeyourgadget/Gadgetbridge@03ee088f090a17d8183492fa38438ff48d0a6ccf` (2026-09-28) |
| `ENC` | `GB/service/devices/huami/Huami2021ChunkedEncoder.java` | same |
| `DEC` | `GB/service/devices/huami/Huami2021ChunkedDecoder.java` | same |
| `SUP` | `GB/service/devices/huami/zeppos/ZeppOsSupport.java` | same |
| `BTLE` | `GB/service/devices/huami/zeppos/ZeppOsBtleSupport.java` | same |
| `AUTH` | `GB/service/devices/huami/zeppos/services/ZeppOsAuthenticationService.java` | same |
| `ECDH` | `GB/util/ECDH_B163.java` | same |
| `CRY` | `GB/util/CryptoUtils.java` | same |
| `FETCH` | `GB/service/devices/huami/operations/fetch/AbstractFetchOperation.java` | same |
| `REPEAT` | `GB/service/devices/huami/operations/fetch/AbstractRepeatingFetchOperation.java` | same |
| `FOP/<Name>` | `GB/service/devices/huami/operations/fetch/Fetch<Name>Operation.java` | same |
| `SVC/<Name>` | `GB/service/devices/huami/zeppos/services/ZeppOs<Name>Service.java` | same |
| `HS` | `GB/devices/huami/HuamiService.java` | same |
| `BLT` | `GB/service/btle/BLETypeConversions.java` | same |
| `HC` | HelioCore (no licence; facts only), `GooseSwift/GooseSwiftApp.swift` | github `a9eelsh/heliocore@ca2a4fa0cd3a10d926c8705957ef91e7251aaa18` (2026-06-03) |
| `TE` | tiny-ECDH-c (Unlicense), `ecdh.c` / `ecdh.h` | `kokke/tiny-ECDH-c@a6095d6e1feaa4e77b84cddda8468d8651ca3a32` |
| `OC-vec` | Vectors computed for this document: tiny-ECDH-c, cross-checked by an independent pure-Python sect163r2 implementation, AES via Python `cryptography` and LibreSSL, CRC via zlib | 2026-09-30 |

HelioCore is the only reference known to run on a real Helio Strap from iOS; Gadgetbridge
covers the whole Zepp OS family and marks the Helio Strap *experimental*
(`GB/devices/huami/zeppos/straps/AmazfitHelioStrapCoordinator.java:33`). Where they
disagree, §9 says so.

---

## 1. Scope and device identification

| Fact | Tag | Source |
|---|---|---|
| The strap advertises the local name **`Amazfit Helio Strap`**, with no MAC suffix. | 🟡 | `GB/devices/huami/zeppos/straps/AmazfitHelioStrapCoordinator.java:39` |
| Zepp OS devices in general may append a 4-character suffix separated by a space or hyphen (`Amazfit Helio Strap 1A2B`, `…-1A2B`). Some devices advertise a second, hyphen-suffixed identity used only for calls. A matcher should accept the exact name, optionally followed by one or more of `-`/space and exactly four `[A-Z0-9]`. | 🟡 | `GB/devices/huami/zeppos/ZeppOsCoordinator.java:99-117` |
| The **Helio Ring** advertises `Amazfit Helio Ring` and speaks the same protocol (same base class, no protocol overrides). Distinguish strap from ring by the name only. | 🟡 | `GB/devices/huami/zeppos/rings/AmazfitHelioRingCoordinator.java:37` |
| Other Zepp OS watches use other exact names (e.g. `Amazfit Balance`); none begins with `Amazfit Helio`. A prefix match on `Amazfit Helio Strap` is therefore sufficient to exclude them. | 🟡 | `GB/devices/huami/zeppos/watches/*Coordinator.java` |
| The strap has **no display** and Gadgetbridge declares it a fitness band. | 🟡 | `AmazfitHelioStrapCoordinator.java:53-55,69-71` |
| Manufacturer data / advertised service UUIDs: **not used by either reference; unknown.** | 🔴 | — (capture item §10) |
| HelioCore's scanner accepts any name containing `helio`, `amazfit` or `zepp` (case-insensitive). Too loose for OpenCircuit: it would also match watches. | 🟡 | `HC:1056` |
| A post-auth **device-info** request (§5.3) returns a flags word; for the Helio Strap Gadgetbridge records it as `0x7f`. It also returns a PnP ID from which a product id / version can be read at PnP bytes 3–4 and 5–6 (little-endian). | 🟡 | `SVC/DeviceInfo:95-101,158-160` |
| Gadgetbridge supports a Bluetooth-Classic transport for some Zepp OS watches. **Ignore it**: iOS is BLE-only, and the Helio uses the BLE path. | 🟡 | `GB/devices/huami/zeppos/ZeppOsCoordinator.java` `getDeviceSupportClass` |

Firmware seen in the wild on Helio Straps: **3.11.0** and **3.11.0.1** (user reports,
Gadgetbridge issues #5986 opened 2026-04-08 and #5843 opened 2026-03-06). 🔴 Pin the version
read from Juan's strap in §10.

---

## 2. GATT map

All Huami-specific UUIDs are 128-bit: `0000XXXX-0000-3512-2118-0009af100700`, written below
as `…XXXX`. Discover characteristics **by UUID across all services** rather than assuming
which service holds them (that is what HelioCore does, `HC:1101-1106`).

| UUID | Name here | Props needed | Direction / use | v1? | Tag / source |
|---|---|---|---|---|---|
| service `0xFEE0` | Huami main service | — | parent of the chunked and activity characteristics | yes | 🟡 `HS:28`, `BTLE:75` |
| `…0016` | **chunked-write** | write (HelioCore uses write-without-response) and notify | phone → device message chunks; device's *chunk acks* may arrive here as notifications | **yes** | 🟡 `HS:57`, `SUP:1074-1075,1145-1156`, `HC:607,894-899` |
| `…0017` | **chunked-read** | notify, write | device → phone message chunks (notify); phone writes its *chunk acks* **to this same characteristic** | **yes** | 🟡 `HS:58`, `BTLE:138`, `SUP:1158-1165` |
| `…0004` | **activity-control** | write, notify | history-fetch control (§6) | **yes** | 🟡 `HS:44`, `SUP:962,973`, `HC:609,944` |
| `…0005` | **activity-data** | notify | history-fetch data packets (§6) | **yes** | 🟡 `HS:45`, `SUP:963,1077-1078`, `HC:610` |
| `0x180D` / `0x2A37` | Heart Rate Measurement | notify | live HR (§7) | **yes** | 🟡 `BTLE:72`, `SUP:1089-1090`, `HC:611` |
| `0x180A` | Device Information Service | read | firmware / hardware revision strings, PnP ID; a leading `V` on the firmware string is stripped by Gadgetbridge | recommended | 🟡 `BTLE:73,78-105` |
| `0x2A2B` | Current Time | write | time-set fallback when the time endpoint is absent (§5.1) | fallback | 🟡 `BTLE:180-183` |
| `0x180F` / `0x2A19` | Battery Level | read/notify | HelioCore looks for it; Gadgetbridge does not use it. **Existence on the Helio unconfirmed.** | optional | 🔴 `HC:612,1106,1127` |
| `…0001` / `…0002` | raw sensor control / data | — | raw accelerometer stream; not needed | no | 🟡 `HS:37-38` |
| `…0023` / `…0024` | file transfer v3 | — | not needed | no | 🟡 `HS:63-64` |
| `00001530-…` service, `…1531`/`…1532` | firmware update | — | **never write** | no | 🟡 `HS:31-34` |

Before sending anything, **enable notifications on `…0017`** (Gadgetbridge does so first,
`BTLE:138`). Enable notifications on `…0004` and `…0005` before a history fetch (§6).

---

## 3. Transport: the chunked ("Huami 2021") protocol

Every command/response except the activity characteristics and standard GATT
characteristics travels as a **message** addressed to a 16-bit **endpoint**, split into
**chunks** that are written to `…0016` (phone → device) or notified on `…0017`
(device → phone).

### 3.1 Chunk header

Byte diagram of one chunk. All multi-byte integers in this protocol are **little-endian**.

```
first chunk of a message (11-byte header):
 +------+-------+------+--------+-------+-----------------------+-----------------+----------
 | 0x03 | flags | 0x00 | handle | count | total length (u32 LE) | endpoint (u16 LE) | data...
 +------+-------+------+--------+-------+-----------------------+-----------------+----------
   [0]    [1]     [2]     [3]      [4]         [5..8]                 [9..10]        [11..]

every later chunk (5-byte header):
 +------+-------+------+--------+-------+----------
 | 0x03 | flags | 0x00 | handle | count | data...
 +------+-------+------+--------+-------+----------
```

| Field | Meaning | Tag / source |
|---|---|---|
| `[0]` = `0x03` | marks a chunk. The receiver ignores anything else on `…0017` except a chunk ack (§3.4). | 🟡 `ENC:136`, `DEC:69-72`, `SUP:1132-1141` |
| `[1]` flags | bit `0x01` **first** chunk · bit `0x02` **last** chunk · bit `0x04` **ack requested** (always set together with *last*) · bit `0x08` **encrypted** (set on *every* chunk of an encrypted message). A single-chunk message therefore has `0x07` (plain) or `0x0F` (encrypted). | 🟡 `ENC:115-135`, `DEC:73-77` |
| `[2]` | "extended header" byte. The phone always writes `0x00`; the receiver skips this byte. | 🟡 `ENC:138-141`, `DEC:79-81`, `SUP:161` (Zepp OS forces the extended form) |
| `[3]` handle | message id, **u8**, per direction. The phone increments its handle **before** each message, so the first message after (re)connect uses `0x01`; it wraps `0xFF → 0x00`. Every chunk of one message carries the same handle. Reset to 0 on every (re)connect/re-auth. | 🟡 `ENC:64,160-163`, `SUP:297-299` |
| `[4]` count | chunk index within the message, u8, starting at `0x00`. | 🟡 `ENC:68,156` |
| `[5..8]` total length | length of the **plaintext** payload in bytes, even for encrypted messages (the ciphertext is longer, §3.3). First chunk only. | 🟡 `ENC:125-128`, `DEC:90-99` |
| `[9..10]` endpoint | 16-bit endpoint number (§3.5 lists them). First chunk only. | 🟡 `ENC:129-130`, `DEC:101` |

### 3.2 Chunk size, MTU and reassembly

- **Max data per chunk** = (ATT MTU − 3) − header size, where header size is 11 for the
  first chunk and 5 for the rest. ATT MTU − 3 is capped at 512. 🟡
  `ENC:111`, `GB/service/btle/AbstractBTLEDeviceSupport.java:92-100`.
  On iOS, use `maximumWriteValueLength(for:)` as the "(MTU − 3)" term: it is what the OS
  actually negotiated. 🔴 (inference; do **not** hard-code 247 as HelioCore does, `HC:843`).
- Gadgetbridge starts every connection assuming MTU 23 (`BTLE:143`, `SUP:158`) and, after
  auth succeeds, requests MTU 247 if the user allows high MTU (`BTLE:191-195`). The device can
  also announce an MTU on endpoint `0x0015` (reply `02` + u16 LE value = MTU − 3,
  `SVC/Connection:49-53`). 🟡
- A chunk is "last" when the remaining payload fits in the current chunk's capacity.
- **Reassembly (device → phone)**: on a *first* chunk, read total length and endpoint and
  start a buffer. For an encrypted message the buffer must hold the *padded ciphertext*
  length, `pad16(total length + 8)` (§3.3). Append every chunk's data. On the *last* chunk,
  decrypt if flagged, **truncate to total length**, and dispatch by endpoint. 🟡 `DEC:89-141`.
- Gadgetbridge ignores chunks whose handle differs from the message being reassembled and
  does not check `count` for gaps or order (`DEC:82-88`). See §9 for why OpenCircuit should
  be stricter.

### 3.3 Encryption

Which endpoints are encrypted is decided per endpoint by the **services list** the device
returns after auth (§5.2); the auth endpoint itself is always plaintext. 🟡 `SVC/Services:62-90`,
`AUTH:57`.

For an encrypted message with plaintext payload `P` of length `L`:

1. Build `P ‖ S ‖ C ‖ Z`, where
   - `S` = the current **encrypted-sequence number** as u32 LE, then increment it by 1 for
     the next encrypted message (it is only consumed by encrypted messages);
   - `C` = **CRC-32** (IEEE 802.3 / zlib / `java.util.zip.CRC32`: reflected, polynomial
     `0xEDB88320`, init and xorout `0xFFFFFFFF`) computed over `P ‖ S`, stored as u32 LE;
   - `Z` = zero bytes to pad the total to a multiple of 16 (none if `L + 8` already is).
   🟡 `ENC:81-99`, `GB/util/CheckSums.java:102-106`
2. **Message key** = the 16-byte **session key** (§4.4) with **every byte XORed with the
   message's handle byte**. 🟡 `ENC:77-80`, `DEC:115-118`
3. Encrypt the padded buffer with **AES-128 in ECB mode, no padding** (each 16-byte block
   independently). No IV. 🟡 `CRY:45-57`, `ENC:101`
4. Chunk the ciphertext as in §3.2, with flag `0x08` on every chunk, and total length = `L`
   (the plaintext length), not the ciphertext length. 🟡 `ENC:116-128`

**Receiving**: decrypt the reassembled ciphertext with the same message-key rule, using the
*incoming* chunk's handle, then keep the first `L` bytes. Gadgetbridge does **not** check the
device's trailing sequence number or CRC (`DEC:106-126`). 🔴 whether the device's trailer has
the same `S ‖ C` layout (the padded length strongly suggests it does; §10 item).

The sequence number starts at the value derived during auth (§4.4) and is per connection.
Gadgetbridge resets it to 0 on reconnect before re-auth overwrites it (`ENC:160-163`).

### 3.4 Chunk-level acks

- When a device → phone message's last chunk has flag `0x04`, the phone acknowledges by
  **writing to `…0017`** (the chunked-*read* characteristic) the 5 bytes
  `04 00 <handle> 01 <count>` where `<handle>` and `<count>` are those of the last chunk
  received. 🟡 `SUP:1131-1137,1158-1165`, `DEC:59-65,87-88,143`
- The device may acknowledge phone → device messages with a notification on `…0016`
  starting `04`, handle at byte `[2]`, count at byte `[4]`. Gadgetbridge only logs it and
  does not wait for it (no flow control). 🟡 `SUP:1145-1156`
- HelioCore sends **no** chunk acks and still completes auth and fetch on a Helio. 🟡
  (`HC` has no ack path). Recommendation: send them as Gadgetbridge does.

### 3.5 Endpoints relevant to v1

| Endpoint | Name here | Default encrypted (before the services list overrides) | Source |
|---|---|---|---|
| `0x0000` | services list | no | 🟡 `SVC/Services:32,38` |
| `0x000A` | config (settings) | yes | 🟡 `SVC/Config:104,116` |
| `0x0015` | connection (MTU announce, ping/pong) | yes | 🟡 `SVC/Connection:30,38` |
| `0x0016` | steps (realtime) | no | 🟡 `SVC/Steps:34,45` |
| `0x0017` | user info | yes | 🟡 `SVC/UserInfo:45,51` |
| `0x001D` | heart rate (realtime control) | no | 🟡 `SVC/HeartRate:36,59` |
| `0x0029` | battery | yes | 🟡 `SVC/Battery:32,38` |
| `0x0043` | device info | no | 🟡 `SVC/DeviceInfo:48,56` |
| `0x0047` | time | no | 🟡 `SVC/Time:39,49` |
| `0x004B` | activity-fetch control (chunked alternative to `…0004`) | yes | 🟡 `SVC/ActivityFetch:30,35` |
| `0x0082` | **authentication** | **never** | 🟡 `AUTH:47,57` |

(Endpoint numbers coincide numerically with some characteristic short UUIDs, e.g. `0x0016`,
`0x0017`. They are unrelated namespaces.)

A **connection ping**: the device may send `03` on endpoint `0x0015`; answer `04` on the
same endpoint. 🟡 `SVC/Connection:54-58`

### 3.6 Worked example A: plaintext, multi-chunk (constructed)

The auth public-key message of §4 (52-byte payload, endpoint `0x0082`, handle `0x01`) at
MTU 23. Capacity: first chunk 20 − 11 = 9 bytes, later chunks 20 − 5 = 15 bytes, so
9 + 15 + 15 + 13 = 52 over four chunks. `OC-vec`

```
chunk 0 (20 B): 03 01 00 01 00 | 34 00 00 00 | 82 00 | 04 02 00 02 a1 e4 ad 02 c2
chunk 1 (20 B): 03 00 00 01 01 | a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c
chunk 2 (20 B): 03 00 00 01 02 | 07 00 00 00 cd 50 73 a0 6d 67 b7 8a 3b c5 f5
chunk 3 (18 B): 03 06 00 01 03 | 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00
```

Flags: `01` first, `00` middle, `06` last + ack-requested. Total length `0x34` = 52.
The same message at MTU 247 is one 63-byte chunk starting `03 07 00 01 00 34 00 00 00 82 00`.

### 3.7 Worked example B: encrypted (constructed, made-up key)

Session key (from worked example C, §4.6): `8c 45 6e 06 23 92 2f ab 73 ce 01 a0 cd dd ee ff`.
Encrypted-sequence number currently `0x2933d231`. Message: a history-fetch start sent through
endpoint `0x004B` as the third message on the connection (handle `0x03`); payload (10 bytes,
§6.2) `01 01 ea 07 09 1e 0c 00 00 08`. `OC-vec`

| Step | Bytes |
|---|---|
| message key = session key XOR `0x03` | `8f 46 6d 05 20 91 2c a8 70 cd 02 a3 ce de ed fc` |
| `P ‖ S` | `01 01 ea 07 09 1e 0c 00 00 08` `31 d2 33 29` |
| CRC-32 over those 14 bytes | `0x9530d05f` → LE `5f d0 30 95` |
| padded plaintext (10 + 4 + 4 = 18 → 32) | `01 01 ea 07 09 1e 0c 00 00 08 31 d2 33 29 5f d0 30 95` + 14 × `00` |
| AES-128-ECB(message key) | `f9 54 ea 42 20 6c b5 96 23 e5 3d c0 11 39 f3 ea e7 6b 3a b5 34 16 39 ae d3 4b de 6d 1c 3b 34 37` |
| next sequence number | `0x2933d232` |

Chunked at MTU 23 (total length field = **10**, the plaintext length):

```
chunk 0 (20 B): 03 09 00 03 00 | 0a 00 00 00 | 4b 00 | f9 54 ea 42 20 6c b5 96 23
chunk 1 (20 B): 03 08 00 03 01 | e5 3d c0 11 39 f3 ea e7 6b 3a b5 34 16 39 ae
chunk 2 (13 B): 03 0e 00 03 02 | d3 4b de 6d 1c 3b 34 37
```

At MTU 247: one 43-byte chunk, `03 0f 00 03 00 0a 00 00 00 4b 00` followed by the 32
ciphertext bytes.

---

## 4. Authentication

### 4.1 Inputs

- **Auth key**: 16 bytes minted by Zepp's cloud when the strap is paired in the Zepp app
  (see `HELIO_KEY_EXTRACTION.md`). Users see it as 32 hex digits, sometimes with a `0x`
  prefix. Accept exactly: optional `0x`/`0X`, then 32 hex digits, surrounding whitespace
  trimmed; reject anything else. 🟡 `AUTH:160-178` (Gadgetbridge also falls back to a default
  key and to raw ASCII bytes for older devices; **do not replicate that**. A wrong key must
  be a visible error.)
- **Curve**: NIST **B-163 = sect163r2** (binary field GF(2¹⁶³), reduction polynomial
  x¹⁶³ + x⁷ + x⁶ + x³ + 1, a = 1, cofactor 2). **Not** sect163k1. 🟡 The parameters in
  `ECDH:56-60` are identical to tiny-ECDH-c's `NIST_B163` set (`TE ecdh.c:100-108`), and
  `OC-vec` confirms them against an independent implementation (base point on curve, order ×
  G = ∞). HelioCore's comment calls it sect163k1 (`HC:1429`) but its constants are also
  B-163's (`HC:1436-1438`).
- **Port tiny-ECDH-c** (Unlicense) for the curve maths: CryptoKit has no binary curves. Keep
  its attribution header.

### 4.2 Wire representation of keys (tiny-ECDH-c layout)

| Item | Size | Layout | Source |
|---|---|---|---|
| private key | 24 bytes | a 192-bit little-endian integer (6 × u32 words, least-significant word first, each word LE) | 🟡 `ECDH:42,407-424`, `TE ecdh.h` |
| public key | 48 bytes | X (24 bytes) then Y (24 bytes), each a field element in the same LE layout. The top 29 bits of each 24-byte element are always zero. | 🟡 `ECDH:43,457-458` |
| shared secret | 48 bytes | the shared **point**, X then Y, same layout (not just X) | 🟡 `ECDH:464-500`, `AUTH:86` |

Private-key rules, as in tiny-ECDH-c (both references do the same): draw 24 random bytes; if
the highest set bit is below bit 81 (degree < 163/2), draw again; the effective scalar is the
value with **every bit from 162 upwards cleared** (in byte terms: byte 20 masked to its low 2
bits, bytes 21–23 zeroed). Apply the same clearing when computing the shared secret. 🟡
`ECDH:442-452,478-484`, `HC:1440-1452,1546`. Use `SecRandomCopyBytes`, not a
non-cryptographic RNG (Gadgetbridge uses `java.util.Random`, `AUTH:135`; don't copy that).

Reject a device public key that is the point at infinity or is not on the curve. 🟡
`ECDH:471-472`

### 4.3 Message sequence (endpoint `0x0082`, plaintext)

```
Phone                                                        Strap
  |  enable notify on …0017                                    |
  |--- [h=1] 04 02 00 02 ‖ phonePub(48) ---------------------->|   52 B  "CMD_PUB_KEY"
  |<-- 10 04 01 ‖ random(16) ‖ strapPub(48) -------------------|   67 B
  |    shared = ECDH(phonePriv, strapPub)                      |
  |    encSeq = u32 LE of shared[0..3]                         |
  |    sessionKey[i] = shared[8+i] XOR authKey[i], i = 0..15   |
  |--- [h=2] 05 ‖ AES(authKey, random) ‖ AES(sessionKey, random) ->|  33 B  "CMD_SESSION_KEY"
  |<-- 10 05 <status> -----------------------------------------|
  |    status 01 = authenticated; 25 = wrong auth key          |
```

| Field | Detail | Tag / source |
|---|---|---|
| request `04 02 00 02` | command `04`; the three bytes `02 00 02` are fixed and unexplained | 🟡 `AUTH:141-146`, `HC:852` |
| reply byte `[0]` | `10` = "response" (any other value: ignore) | 🟡 `AUTH:67-70`, `HS:224` |
| reply byte `[1]` | echoes the command (`04` or `05`) | 🟡 `AUTH:72` |
| reply byte `[2]` | status: `01` success. On the `04` reply, anything else is a failure. On the `05` reply, `25` means **wrong auth key**; any other non-`01` value is an unspecified failure. | 🟡 `AUTH:74-77,112-119`, `HC:867,887-888` |
| `04` reply `[3..18]` | 16-byte device random | 🟡 `AUTH:84`, `HC:869` |
| `04` reply `[19..66]` | device public key, 48 bytes (§4.2) | 🟡 `AUTH:85`, `HC:870` |
| AES in `05` | **AES-128-ECB, no padding**, one 16-byte block each: first with the auth key, second with the **session key** | 🟡 `AUTH:98-104`, `CRY:45-50`, `HC:875-880` |

### 4.4 Deriving the session parameters

From the 48-byte shared secret `s` (§4.2 layout):

- **encrypted-sequence seed** = `s[0..3]` read as **u32 little-endian** (the low 32 bits of the
  shared point's X). 🟡 `AUTH:87`, `BLT:229-231`, `HC:872`
- **session key** = `s[8..23]` (16 bytes, the middle of X's encoding) XOR the auth key,
  byte for byte. 🟡 `AUTH:89-92`, `HC:873-874`

Both are installed **as soon as the `04` reply is processed**, before the `05` message is
sent (the `05` message itself is plaintext). After `10 05 01`, every endpoint that the
services list marks as encrypted uses them (§3.3). 🟡 `AUTH:95`

On `10 05 25`, Gadgetbridge tells the user the key is wrong and disconnects (`AUTH:151-158`).
OpenCircuit should do the same and surface a "key rejected: re-extract it" state (the key is
invalidated by unpairing in Zepp or a hard reset, see `HELIO_KEY_EXTRACTION.md`).

### 4.5 Timing notes

HelioCore waits ~0.4 s after enabling notifications before sending the public key
(`HC:846`). 🔴 whether the delay is needed; waiting for the notify-enabled callback should
suffice.

### 4.6 Worked example C: full handshake (constructed, made-up keys)

Made-up inputs (**not** a real strap or a real key). `OC-vec`

| Input | Value |
|---|---|
| phone private key (as drawn) | `01 02 03 … 18` (bytes `0x01`…`0x18`) |
| phone effective scalar (bits ≥ 162 cleared) | `01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 01 00 00 00` |
| strap private key (simulated) | bytes `0x81`…`0x98`, effective `81 82 … 94 01 00 00 00` |
| auth key | `00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff` |
| strap random | `f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff` |

Outputs:

```
phonePub X = a1 e4 ad 02 c2 a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c 07 00 00 00
phonePub Y = cd 50 73 a0 6d 67 b7 8a 3b c5 f5 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00
strapPub X = a3 31 15 77 49 a9 09 f0 67 ad 23 2a 5c 17 ab 6f 21 72 c3 0c 00 00 00 00
strapPub Y = f4 f5 5b 1a df fc 66 c5 f3 5f 29 c2 5f 89 da 07 73 fd 25 6a 05 00 00 00
shared   X = 31 d2 33 29 56 1a c3 f2 8c 54 4c 35 67 c7 49 dc fb 57 ab 1b 01 00 00 00
shared   Y = 06 e8 17 31 4f 23 79 8d ed fc f2 14 68 60 70 12 e1 9e c7 be 04 00 00 00
(shared is identical whichever side computes it)

encSeq seed      = 0x2933d231            (shared[0..3] = 31 d2 33 29, LE)
session key      = 8c 45 6e 06 23 92 2f ab 73 ce 01 a0 cd dd ee ff
AES(auth, rnd)   = e8 55 41 bb 23 2f 07 09 90 89 75 3d 86 c0 dd f0
AES(sess, rnd)   = e0 f4 c3 cc 1c 86 76 7b dd 16 70 a2 1d 60 d5 4f
```

Strap's `04` reply payload (67 bytes):
`10 04 01 f0 f1 … ff` then strapPub X, then strapPub Y.

Phone's `05` message (33 bytes, handle 2), as one chunk at MTU 247:
`03 07 00 02 00 21 00 00 00 82 00 05 e8 55 41 bb 23 2f 07 09 90 89 75 3d 86 c0 dd f0 e0 f4 c3 cc 1c 86 76 7b dd 16 70 a2 1d 60 d5 4f`.

These vectors are suitable as unit-test fixtures for the Swift port (they are ours, not
copied from any project).

---

## 5. Post-auth session setup

Gadgetbridge's order after `10 05 01` (🟡 `SUP:901-957`, `BTLE:191-195`):

1. request MTU 247 (iOS: nothing to do, the OS negotiates);
2. request the **services list** (§5.2);
3. on the reply: set the time (§5.1), request device info (§5.3), then initialise each
   supported service (battery request, config capabilities, user info, realtime-steps off…);
4. history fetch is started separately (by the user or a schedule).

HelioCore's minimal path skips 1–3 entirely: auth, then fetch over `…0004`/`…0005` with
plaintext writes, and it works on a Helio (🟡 `HC:886-892,902-930`). **Recommended v1
order**: auth → services list → time set → battery → read HEALTH config (§5.5) → fetch. Time
set matters most: once the Zepp app is gone, **nothing else sets the strap's clock**, and
every history timestamp is in the strap's clock (§6.4).

### 5.1 Time (endpoint `0x0047`, plaintext by default)

Use it if the services list contains `0x0047`, otherwise write the same 11 time bytes to
the standard Current Time characteristic `0x2A2B`. 🟡 `SUP:934-940`, `BTLE:180-183`

**Set time** = `05` followed by 11 bytes (12 bytes total): 🟡 `SVC/Time:80-89`,
`GB/service/devices/huami/HuamiUtils.java:152-182`

| Offset (after `05`) | Size | Meaning |
|---|---|---|
| 0 | u16 LE | year |
| 2 | u8 | month 1–12 |
| 3 | u8 | day of month |
| 4 | u8 | hour 0–23 (local) |
| 5 | u8 | minute |
| 6 | u8 | second |
| 7 | u8 | day of week, **Sunday = 0 … Saturday = 6** (not the GATT convention) |
| 8 | u8 | fraction of second in 1/256 |
| 9 | u8 | `08` if daylight-saving time is currently in effect, else `00` |
| 10 | i8 | current UTC offset **including DST**, in quarter-hours (UTC+2 → `08`, UTC−5 → `ec`) |

Reply: `06 <status>` (status `01` observed). The device rejects the 10-byte GATT form with
"out of range". 🟡 `SVC/Time:64-66`, `HuamiUtils.java:153-157`

**Next DST transition** = `07`, then u32 LE Unix seconds of the next transition, then
**i16** LE the offset change in seconds (e.g. `+3600` spring forward, `−3600` fall back).
Skip it if the zone has no future transition. Reply `08 <status>`. 🟡 `SVC/Time:91-114`

Example (constructed): 2026-09-30 12:34:56.000, a Wednesday, Europe/Madrid (UTC+2, DST on)
→ `05 ea 07 09 1e 0c 22 38 03 00 08 08`.

### 5.2 Services list (endpoint `0x0000`, plaintext)

Request `03`. Reply: `04`, u16 LE count, then count × (u16 LE endpoint, u8 encrypted flag
`00`/`01`; other flag values = leave the default). 🟡 `SVC/Services:58-90`. Use it to
(a) know which endpoints exist (e.g. whether `0x004B` and `0x0047` are available), and
(b) override each endpoint's encryption flag from §3.5.

### 5.3 Device info and battery

- **Device info** (endpoint `0x0043`, plaintext): request `01`. Reply `02 01`, then u64 LE
  flags, then fields present by flag bit: bit0 = a length-prefixed blob (skip), bit1 =
  serial number (NUL-terminated UTF-8), bit2 = hardware version (NUL-terminated), bit3 =
  firmware version (NUL-terminated), bit4 = 7-byte PnP ID. If the services list lacks
  `0x0043`, read DIS `0x180A`. 🟡 `SVC/DeviceInfo:77-141`. The serial number is a personal
  identifier: never log it or commit it.
- **Battery** (endpoint `0x0029`, encrypted by default): request `03`. Reply `04` + 20 bytes
  (21 total). Payload byte `[2]` = level in %, byte `[3]` = `00` not charging / `01`
  charging; bytes `[11..18]` hold a last-charge date (u16 year, month, day, h, m, s, i8
  quarter-hour offset) and `[20]` the last charge level. 🟡 `SVC/Battery:47-70`, `GB/service/devices/huami/HuamiBatteryInfo.java:60-103`
  (offsets given here relative to the full reply, i.e. Gadgetbridge's offsets + 1).

### 5.4 User info (endpoint `0x0017`, encrypted by default), optional

Gadgetbridge sends it on every connect if the user profile is complete. 🟡
`SVC/UserInfo:93-146`. Probably feeds on-device calorie/PAI maths; 🔴 whether the strap
records anything differently without it. Layout:

`01` · `4f 07 00 00` (fixed) · u16 LE birth year · u8 month · u8 day · u8 gender (`00` male,
`01` female, `02` other) · u16 LE height cm · u16 LE weight in **kg × 200** · u64 LE user id
(any stable number) · region as UTF-8 then `00` · `09` (fixed, unexplained) · display name as
UTF-8 then `00`. Reply `02 <status>`.

### 5.5 Settings that decide what is RECORDED (config endpoint `0x000A`, encrypted by default)

The strap only records a metric if its monitoring setting is on. The Zepp app sets them;
**read them after auth** and warn the user when one is off, rather than silently fetching
nothing.

**Commands** 🟡 `SVC/Config:104-111,283-388,938-960`

| Command | Bytes |
|---|---|
| capabilities | send `01` → reply `02`, u8 service version (≤ 3 understood), u8 group count, group ids… |
| read | send `03`, u8 include-constraints (`01`/`00`), u8 group, u8 arg count, arg codes… (arg count `00` asks for all args, 🔴) |
| read reply | `04`, u8 status (`01` ok), u8 group, u8 group version, u8 includes-constraints, u8 entry count, then entries |
| write | send `05`, u8 group, u8 group version, `00`, u8 entry count, then entries (value only, no constraints). **One message per group.** |
| write ack | `06`, u8 status |

**Entry** = u8 arg code, u8 type, value. Value encodings (LE throughout): 🟡
`SVC/Config:432-444`, `GB/service/devices/huami/zeppos/services/config/*.java`

| Type | Code | Value | Extra bytes when constraints are included |
|---|---|---|---|
| bool | `0x0b` | 1 byte, `00`/`01` (anything else: stop parsing) | none |
| byte | `0x10` | 1 byte | u8 n, then n allowed values |
| byte list | `0x11` | u8 n, n bytes | u8 m, then m allowed values |
| short | `0x01` | i16 | i16 min, i16 max |
| short list | `0x02` | u8 n, n × i16 | u8 min count, u8 max count, i16 min, i16 max |
| int | `0x03` | i32 | i32 min, i32 max |
| string | `0x20` | UTF-8 up to `00` | u8 max length |
| string list | `0x21` | UTF-8 up to `00` | u8 max length, u8 n, n NUL-terminated strings |
| hh:mm | `0x30` | u8 hour, u8 minute | none |
| timestamp | `0x40` | i64 ms | none |
| int (unbounded) | `0x50` | i32 | none |

An unknown type code makes the rest of the reply unparseable (no length field): keep what
was parsed and stop. 🟡 `SVC/Config:1025-1032`

**HEALTH group = `0x08`** (Gadgetbridge understands versions 1–3 and writes version `03`).
🟡 `SVC/Config:399,516-539`

| Arg | Type | Meaning | Relevant fetch type(s) |
|---|---|---|---|
| `0x01` | byte | all-day HR monitoring: `00` off, `ff` "smart"/auto, `N` = every N minutes (Gadgetbridge caps at 120) | activity HR, resting/max HR, HRV 🔴 | 
| `0x04` | bool | HR monitoring during activity | activity HR 🔴 |
| `0x05` | bool | share HR with third parties. 🔴 Probably the Zepp app's **"Heart Rate Push"** switch (Zepp › Device › Helio Strap › Health Monitoring), which the strap needs for standard-HR broadcast (§7) | live HR |
| `0x11` | bool | high-accuracy sleep monitoring (uses HR for sleep; needed for REM staging 🔴) | sleep session |
| `0x12` | bool | sleep breathing-quality monitoring. Gadgetbridge notes it is required for **sleep SpO₂** (`FOP/Spo2Sleep:31-33`); 🔴 likely also for sleep respiratory rate | `0x26`, `0x38` 🔴 |
| `0x13` | bool | stress monitoring | `0x13` 🟡 |
| `0x31` | bool | all-day SpO₂ monitoring | automatic `0x25` 🟡 |
| `0x02` / `0x03` / `0x32` | byte | high-HR / low-HR / low-SpO₂ alert thresholds | — |

HR-interval encoding 🟡 `SVC/Config:1508-1523`. Gadgetbridge v0.90 reportedly **hides** the
HR-interval setting for the Helio Strap because its HR is always on (third-hand, from its
release notes; 🔴). **Temperature** has no known switch in any reference: 🔴 assume it is
always recorded.

Example (constructed): enable stress monitoring → payload `05 08 03 00 01 13 0b 01`.

---

## 6. History fetch

### 6.1 Channels

| Role | Path A (legacy characteristic) | Path B (chunked endpoint) |
|---|---|---|
| control out (phone → strap) | write to `…0004` (plaintext) | message on endpoint `0x004B` (encrypted per services list) |
| control in (strap → phone) | notification on `…0004` | message on endpoint `0x004B` |
| data | notifications on `…0005` (plaintext) | **same**: notifications on `…0005` |

Gadgetbridge uses Path B whenever the services list includes `0x004B`, else Path A
(`SUP:968-976`, `SVC/ActivityFetch:44-52`). HelioCore uses Path A on the Helio and it works
(`HC:902-946`). Control messages have **identical bytes** on both paths. 🟡. Recommendation:
Path A first (simplest, proven on the Helio); Path B only if Path A is refused.

Notifications: enable `…0004` before the first command; enable `…0005` before sending the
"fetch data" command; Gadgetbridge disables both when the whole batch is done
(`GB/service/devices/huami/HuamiFetcher.java:170-202`, `FETCH:219`). 🟡

### 6.2 One fetch round

```
Phone                                                          Strap
  |-- 01 <type> <since: 8 bytes> ------------------------------>|  10 B  "start"
  |<- 10 01 01 <len u32> <start: 8 bytes> ---------------------|  15 B (16 B seen with a trailing 00)
  |   if len == 0: skip to ACK (keep)                           |
  |-- 02 ------------------------------------------------------>|  "fetch data"
  |<- …0005: <ctr> <data…>   (repeated)                         |
  |<- 10 02 01 [crc32 u32]   (3 or 7 bytes) -------------------|  "transfer done"
  |-- 03 <ack mode> ------------------------------------------->|  "ack"
  |<- 10 03 …   ----------------------------------------------|  round finished
```

| Message | Layout | Tag / source |
|---|---|---|
| **start** | `01`, u8 fetch type (§6.5), then the 8-byte **since** timestamp: u16 LE year, month, day, hour, minute (local), u8 second, i8 UTC offset **including DST** in quarter-hours. Gadgetbridge sends second = `00` by default (minute precision; seconds broke the GTR 3). | 🟡 `FETCH:145-151`, `SUP:679-688`, `BLT:121-134,380-387`, `GB/service/devices/huami/HuamiFetcher.java:150-156`, `HC:926-928,1258-1266` |
| **start reply** | `10 01 <status>`; status `01` = ok, else the type is unsupported/refused: skip it. Then u32 LE **expected length** (bytes of data excluding the per-packet counter bytes), then the 8-byte **start** timestamp of the first record, same format as *since*. Gadgetbridge accepts 15 bytes, or 16 with a trailing `00`. | 🟡 `FETCH:153-221` |
| **fetch data** | the single byte `02` | 🟡 `FETCH:220`, `HC:944` |
| **data packet** | on `…0005`: byte `[0]` = u8 **packet counter** starting at `00` for each round and incrementing by 1 (wrapping); the rest is data. Concatenate the data parts. | 🟡 `FETCH:123-143`, `HC:955-965` |
| **transfer done** | `10 02 <status>`; status `01` = ok. 7-byte form carries u32 LE **CRC-32** (same CRC as §3.3) of the concatenated data parts, counters excluded. | 🟡 `FETCH:223-246` |
| **ack** | `03`, then ack mode (§6.3) | 🟡 `FETCH:260-277` |
| **ack reply** | `10 03 …`; Gadgetbridge treats it as "round finished" and only then starts the next round/type | 🟡 `FETCH:173-176` |

Worked example D (constructed, made-up readings): fetch HRV since 2026-09-29 00:00 in UTC+2.
`OC-vec`

```
→ 01 49 ea 07 09 1d 00 00 00 08
← 10 01 01 0c 00 00 00 ea 07 09 1d 00 05 00 08      len = 12, first record 00:05:00 (+02:00)
→ 02
← […0005] 00 8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39   counter 00; two 6-byte HRV records
← 10 02 01 39 62 bb d7                               CRC-32 of the 12 data bytes = 0xd7bb6239
→ 03 09                                              ack, keep on strap
← 10 03 01                                           (status byte 🔴: only "10 03" is checked)
```

The two records decode (§6.5) to 42 ms at 1790633100 (2026-09-28T22:05:00Z) and 57 ms at
1790633400 (22:10:00Z).

### 6.3 Ack: keep vs delete (critical)

| Ack mode byte | Meaning | Tag / source |
|---|---|---|
| `01` | "saved on the phone": the strap marks the data as synced and **stops offering it**; Gadgetbridge notes the detailed data then appears to be discarded and is never re-sent | 🟡 `FETCH:266-270` |
| `09` | acknowledged **but kept** marked as unsynced on the strap (non-destructive) | 🟡 `FETCH:266-270`, `HC:969,986` |

Gadgetbridge's rules on Zepp OS (🟡 `FETCH:204-209,236-258`):

- expected length 0 → send `03 09` and wait for the ack reply;
- CRC present and wrong → send `03 09` (keep);
- processing failed, or packet-counter gap (the round is marked invalid) → `03 09`;
- otherwise `03 01`, unless the user chose "keep data on device" → `03 09`.

**OpenCircuit rule**: send `03 09` during development (so Zepp/Gadgetbridge can pull the same
window for side-by-side validation) and, in production, send `03 01` **only after the parsed
round is durably committed** to the local store (mirroring `HistoryCommitGate`). Any failure
path → `03 09`.

Unknowns (🔴, §10): whether `01` frees strap storage immediately; how long the strap retains
unsynced data when only `09` is ever sent (it may eventually overwrite the oldest); whether a
later fetch with an older *since* re-delivers data acked with `09` (it should: *since* is
chosen by the phone).

### 6.4 Rounds, cursors and timestamps

- The strap returns at most a limited window per round. After processing a round, set the
  next *since* to the **last record's time + 1 minute** and start another round of the same
  type while: the round advanced by ≥ 1 s, fewer than ~11 rounds have run, and the new
  *since* is not in the future. 🟡 `REPEAT:64-114` (file lines of
  `processBufferedData`/`needsAnotherFetch`). HelioCore does the same with ≤ 20 rounds
  (`HC:973-981`).
- First-ever cursor: Gadgetbridge starts 100 days back (`FETCH:293-303`). Keep one cursor
  **per fetch type**.
- **Per-minute types** (activity, stress-auto, temperature) carry no timestamps: record *i*
  is at `start + i minutes`, where *start* comes from the start reply. Interpret the start
  reply's local fields **with its own quarter-hour offset byte**: absolute instant = local
  fields − offset × 15 min. 🟡 `BLT:161-184`, `FOP/Activity:112-121`. (HelioCore ignores the
  offset byte and uses the phone's zone, `HC:1268-1285`. Wrong whenever the strap's zone
  differs from the phone's, e.g. after travel or a DST change before a time set.)
- **Records with their own timestamp** use a u32 LE **Unix epoch seconds (UTC)** value, often
  followed by an i8 UTC offset in quarter-hours for local display. 🟡 (per type below)

### 6.5 Fetch types

"GB maps to" is where Gadgetbridge stores the value. "Helio" says whether Gadgetbridge
schedules the fetch for the Helio Strap: it queues a type when the coordinator reports
support, and the strap inherits all Zepp OS defaults except display-dependent ones
(`GB/service/devices/huami/HuamiFetcher.java:54-112`,
`GB/devices/huami/zeppos/ZeppOsCoordinator.java:173-249,611-617`).

| Code | Name | Record layout (LE) | Rate / timestamps | Units / scaling | GB maps to | Helio in GB | Tag / source |
|---|---|---|---|---|---|---|---|
| `0x01` | **activity** | **8 bytes/min** on Zepp OS: `[0]` kind, `[1]` intensity, `[2]` steps, `[3]` HR, `[4]` unknown, `[5]` sleep, `[6]` deep-sleep, `[7]` REM (sleep bytes: use low 7 bits) | 1/min from *start* | steps = count in that minute; HR bpm, `ff` or `00` = no reading (HelioCore drops them; GB stores raw); intensity 0–255 (GB divides by 256). CRC is **not** checked by GB for this type. | per-minute activity sample | yes (always) | 🟡 `FOP/Activity:71-164`, `SUP:984-986`, `HC:1180-1193` |
| `0x02` | manual HR | 6 bytes: u32 ts, i8 tz (¼ h), u8 bpm | event | bpm | manual-HR sample | yes | 🟡 `FOP/HeartRateManual:63-90` |
| `0x0d` | PAI | 102 bytes: u8 type (`05` valid, `00` pre-reset: skip), u32 ts, i8 tz, 31 unknown, f32 PAI low, f32 moderate, f32 high, u16 min low, u16 min moderate, u16 min high, f32 PAI today, f32 PAI total, 39 unknown | daily | PAI points, minutes | PAI sample | yes | 🟡 `FOP/Pai` `handleActivityData` |
| `0x12` | stress (manual) | 5 bytes: u32 ts, u8 stress | event | 0–100 | stress, type manual | yes | 🟡 `FOP/StressManual:64-95` |
| `0x13` | **stress (auto)** | 1 byte/min, `ff` = none (the minute still advances) | 1/min from *start* | 0–100; bands 0–39 relaxed, 40–59 mild, 60–79 moderate, 80–100 high | stress, type automatic | yes | 🟡 `FOP/StressAuto:62-91`, `HC:1195-1199` |
| `0x25` | **SpO₂** (normal: manual + auto) | one leading **version byte `02`** per round, then 65-byte records: u32 ts, u8 value (**bit 7 set = automatic**, value = low 7 bits), 60 unknown bytes. Other versions: reject. | event | % | SpO₂ sample, type auto/manual | yes | 🟡 `FOP/Spo2Normal:64-103`, `HC:1201-1212` |
| `0x26` | SpO₂ (sleep) | version byte `02`, then 30-byte records: u32 ts, u8 SpO₂, u8 duration, 6 bytes "high", 6 bytes "low", 8 bytes signal quality, 4 bytes "extend" | per sleep | %; GB notes it often differs by ~1 from `0x25` | **not stored** | **not scheduled** | 🟡 `FOP/Spo2Sleep:48-93` (no queue entry in `HuamiFetcher.java`) |
| `0x2e` | **temperature** | 8 bytes/min: i16 unknown (`0x7fff` observed), **i16 temperature**, i16 unknown, i16 unknown (`0x5a5a` observed in both) | 1/min from *start* | **centi-°C** (÷100), skin at the wrist/arm | skin temperature | yes (no display) | 🟡 `FOP/Temperature:61-96`, `HC:1168-1178` |
| `0x38` | **sleep respiratory rate** | 8 bytes: u32 ts, i8 tz, u8 rate, u8 unknown (`00`), u8 unknown (`01`, sometimes `02`/`04` near waking) | during sleep | breaths/min | resp-rate sample | yes | 🟡 `FOP/SleepRespiratoryRate:62-90`, `HC:1225-1233` |
| `0x3a` | **resting HR** | 6 bytes: u32 ts, i8 tz, u8 bpm | ~daily (Zepp shows it per day) | bpm | resting-HR sample | yes | 🟡 `FOP/HeartRateResting:63-91`, `HC:1214-1222` |
| `0x3d` | **max HR** | 6 bytes: u32 ts, i8 tz, u8 bpm | ~daily 🔴 | bpm | max-HR sample | yes | 🟡 `FOP/HeartRateMax:63-90` |
| `0x48` | **sleep session** | **594-byte** records, see §6.6 | per night | minutes | sleep-session blob; stages overlaid on activity | yes | 🟡 `FOP/SleepSession:59-85` |
| `0x49` | **HRV** | 6 bytes: u32 ts, u8 unknown (🔴 probably the tz byte, as in the 6-byte HR records), u8 HRV | a few per day/night 🔴 | **ms**; statistic **unknown** (RMSSD vs SDNN, 🔴) | HRV value | yes (no display) | 🟡 `FOP/Hrv:59-85`, `HC:1236-1245` |
| `0x2c` | statistics | opaque files; fetched only so the strap frees memory | — | — | discarded | yes | 🟡 `FOP/Statistics` |
| `0x05` / `0x06` | workout summary / detail | binary summary + track; **out of scope for v1**, not specified here | per workout | — | workouts | yes | 🟡 `FOP/SportsSummary`, `FOP/SportsDetails` |
| `0x07` | debug logs | — | — | — | — | no | 🟡 `GB/…/fetch/HuamiFetchDataType.java:24` |

Length rules to enforce before parsing (a violation = reject the round, ack `09`): activity
multiple of 8; stress-auto any; manual/max/resting HR and HRV multiple of 6; temperature
and resp-rate multiple of 8; SpO₂ (length − 1) multiple of 65; sleep SpO₂ (length − 1)
multiple of 30; sleep session multiple of 594; PAI multiple of 102; manual stress multiple
of 5. 🟡 (the per-type sources above)

**Activity `kind` byte** (Zepp OS table, 🟡 `GB/devices/huami/HuamiExtendedSampleProvider.java:35-42,151-170`):
`0x40` (64) outdoor running · `0x73` (115) not worn · `0x76` (118) charging · `0x78` (120)
sleep. All other values are unmapped in Gadgetbridge and shown as generic activity; only
"walking" is named for the Helio (issue #5843, 2026-03-06). 🔴 full table.

**Sleep staging without a session record**: when no `0x48` session covers a minute,
Gadgetbridge falls back to thresholds on the activity record's REM/deep bytes (REM if REM > 55,
else deep if deep > 42, else light), which it calls arbitrary (`HuamiExtendedSampleProvider.java:127-147`).
🔴 Prefer the session record; otherwise feed per-minute HR/motion into OpenCircuit's own
`SleepStaging`.

### 6.6 Sleep session record (`0x48`), 594 bytes

🟡 `GB/devices/huami/HuamiSleepSessionSampleProvider.java:70-195`

| Offset | Type | Meaning |
|---|---|---|
| `0x000` | u32 | session timestamp (Unix s) |
| `0x004` | u32 | "midnight" reference: local midnight (as Unix s) of the day the session belongs to |
| `0x008`, `0x009` | u8, u8 | both `01` in observed data, unexplained |
| `0x00A` | u16 | sleep start, minutes |
| `0x00C` | u16 | sleep end, minutes |
| `0x015` | u8 | average HR during sleep, bpm |
| `0x016` | u8 | sleep score |
| `0x054` | u8 | number of stages *n* (0 = no staging; skip the record) |
| `0x056` + 5·*i* | u16, u16, u8 | stage *i*: start minute, end minute, stage type |
| `0x24A` | u16 | total REM, minutes |
| `0x24C` | u16 | total light, minutes |
| `0x24E` | u16 | total deep, minutes |
| `0x250` | u16 | total awake, minutes |

**Minute fields** are minutes counted from `midnight − 24 h` (the previous local midnight):
absolute = `midnight − 86400 + minutes × 60`. The source comments call the base "noon of
the previous day", but the arithmetic uses midnight − 24 h; 🔴 until a capture decides.
**Stage types**: `04` light · `05` deep · `07` awake · `08` REM · anything else = generic
sleep. The stage table fits at most 100 entries before `0x24A` (🔴 inference). Gadgetbridge
uses each stage's start and the session end, ignoring stage end fields (🟡); OpenCircuit
should use both and flag gaps.

---

## 7. Live data

### 7.1 Standard heart rate (`0x180D` / `0x2A37`)

- **With auth** (Gadgetbridge's path): enable notify on `0x2A37`, then send `04 01` (start) on
  endpoint `0x001D`, then `04 02` ("continue") **every second** to keep it running; `04 00`
  stops it. Reply `05 <status>` (`00` observed as success). 🟡 `SVC/HeartRate:36-47,112-183`
- The same endpoint pushes **sleep events**: `06 01` fell asleep, `06 00` woke up. 🟡
  `SVC/HeartRate:74-88` (useful as a sleep-window hint).
- **Without auth (Tier 0)**: Amazfit documents a **"Heart Rate Push"** switch (Zepp › Device ›
  Amazfit Helio Strap › Health Monitoring) that makes the strap serve HR to third-party
  devices over "the standard Bluetooth protocol" (support.amazfit.com, "How to set the heart
  rate push function?", © 2025, fetched 2026-09-30). HelioCore subscribes to `0x2A37`
  directly after auth without the `0x001D` start command (`HC:1105,1125`). 🔴 whether an
  **unauthenticated** central gets `0x2A37` notifications with Heart Rate Push on (§10).
- Parse `0x2A37` per the Bluetooth HRS spec: flags bit0 → u8/u16 HR; bit3 energy expended
  present; bit4 RR intervals present (u16, 1/1024 s). Gadgetbridge only accepts the
  2-byte u8 form (`SVC/HeartRate:158-167`); HelioCore only the u8 form (`HC:1247-1252`).
  🔴 whether the Helio ever sends RR intervals.

### 7.2 Realtime steps (endpoint `0x0016`)

`05 01`/`05 00` enable/disable (ack `06 <status> <enabled>`); notifications `07` + 13 bytes,
steps = u16 LE at offset 1 of those 13. Gadgetbridge turns it **off** on connect because the
setting persists across connections. 🟡 `SVC/Steps:36-110`. Not needed for v1.

### 7.3 Battery

Use the battery endpoint (§5.3). `0x2A19` only if discovery shows it exists. 🔴

---

## 8. What Gadgetbridge marks unsupported / experimental for the Helio Strap

- The whole device is flagged **experimental** (`AmazfitHelioStrapCoordinator.java:33`).
- Device "sources" (firmware-matching ids) are an explicit **TODO/empty**
  (`AmazfitHelioStrapCoordinator.java:43-45`): firmware updates through Gadgetbridge are not
  supported.
- **Manual HR measurement** is disabled for all Zepp OS devices ("sometimes never finishes",
  `ZeppOsCoordinator.java:178-180`).
- **Sleep SpO₂ (`0x26`)** is parsed but never stored nor scheduled (§6.5).
- **Activity types** beyond walking are unmapped (issue #5843, open, 2026-03-06).
- **Workout HR** is persisted at 1/min only; the strap records ~1 Hz during workouts
  (issue #5617, open, opened 2025-12-14; maintainer: "can be implemented, but needs some work").
- **VO₂ max** only comes from workouts, which are hard to start on a screenless strap
  (issue #5986, 2026-04-08). The same thread reports that HRV/SpO₂/PAI/sleep stages were
  missing on the first Gadgetbridge syncs and appeared on later syncs; the maintainer's
  explanation was that data the official app had already synced is not re-offered. This is
  consistent with ack `01` semantics (§6.3).
- Live-activity and speed-zone screens, sedentary reminders: broken or unsupported (issue
  #5799, 2026-02-15). Not relevant to OpenCircuit.

---

## 9. Pitfalls, defensive handling, and where the references disagree

| # | Topic | Gadgetbridge | HelioCore | OpenCircuit should |
|---|---|---|---|---|
| 1 | Fetch control transport | `0x004B` encrypted when listed, else `…0004` | always `…0004` plaintext | start with `…0004`; fall back to `0x004B` (§6.1) |
| 2 | Start-reply timezone | honours the reply's offset byte | uses the phone's zone | honour the offset byte (§6.4) |
| 3 | Ack timing | after CRC check + successful processing | `03 09` immediately, before parsing, no CRC check | CRC check → parse → durable commit → ack (§6.3) |
| 4 | Activity record size | fixed 8 on Zepp OS | 8 if length divisible by 8, else 4 | fixed 8 (4 would be ambiguous whenever a round is a multiple of 8) |
| 5 | HR-type `ff`/`00` | stored raw | dropped | drop (no reading), never write 0/255 bpm |
| 6 | Chunk acks | sent | never sent | send (§3.4) |
| 7 | MTU | 23 until auth, then asks for 247 | hard-coded 247 | use the OS-negotiated `maximumWriteValueLength` |
| 8 | Incoming encrypted messages | decrypted | **dropped** | decrypt (§3.3) |
| 9 | Packet-counter gap | round invalid → ack `09` | logged, continues | treat as invalid round → ack `09`, retry |
| 10 | Rounds per type | ≤ ~11 | ≤ 20 | bounded loop; persist cursor per type |
| 11 | Curve name | B-163 constants | comment says sect163k1, constants are B-163 | sect163r2 (§4.1) |
| 12 | Default key on missing/short key | silently uses a built-in default | refuses | refuse; clear UI error |
| 13 | Private-key RNG | `java.util.Random` | `SecRandomCopyBytes` | `SecRandomCopyBytes` |

Other defensive points:

- **Handle interleaving**: Gadgetbridge drops chunks whose handle differs from the message in
  progress, so a lost *last* chunk stalls reassembly until something resets it. On a new
  *first* chunk, discard any incomplete message and start over. 🔴 (recommendation)
- **Re-auth resets everything**: new handle counter (0), new session key, new sequence seed;
  never reuse them across connections (`SUP:297-299`). Gadgetbridge notes that initialising
  twice changes the session key mid-flight and breaks decryption (`SUP:909-913`).
- **Config writes** carry Gadgetbridge's own group version (HEALTH `03`), not necessarily the
  version the device reported (`SVC/Config:944-947`). 🔴 whether a v1/v2 device accepts that;
  prefer echoing the version from the read reply.
- **Start-reply length**: accept 15 bytes, or 16 when the extra byte is `00`
  (`FETCH:190-195`); treat other lengths as a failed round.
- **Competing central**: while the Zepp app is installed and running, it reconnects to the
  strap and may win the connection. Auth failures other than `25` right after connect may
  mean another central holds the strap. 🔴 (plan-of-record §7; no protocol-level signal
  known).
- **Timestamps you can't trust**: after a battery drain the strap clock may be wrong until the
  time is set; drop records dated in the future or before the strap's first sync.
- **Temperature sentinels**: the first and last two i16 fields hold constants; 🔴 whether the
  temperature field itself ever holds a "no reading" value (treat `0x7fff`/`0x8000` and
  anything outside ~20–45 °C as missing; HelioCore filters 20–45 for display, `HC:1007-1008`).

---

## 10. Promote to 🟢: capture checklist (Juan's strap)

Record firmware (DIS `0x2A26` or endpoint `0x0043`) with every run. Keep captures in
`desktop/captures/` (gitignored); commit findings only. Use `03 09` (keep) for every ack.

1. **Advertisement**: name exactly as broadcast (suffix or not); manufacturer data bytes;
   advertised service UUIDs; whether a second hyphen-suffixed identity appears.
2. **GATT dump**: every service and characteristic with properties; confirm `…0016`,
   `…0017`, `…0004`, `…0005` sit under `0xFEE0`; whether `0x180F/0x2A19` exists; the write
   types `…0016` and `…0004` accept.
3. **Auth** against the real key: `10 04 01` reply length is 67; `10 05 01` success; then a
   deliberately wrong key returns `10 05 25`. Promotes §4.
4. **Services list**: full endpoint table with encryption flags (is `0x004B` present? which
   are encrypted?). Promotes §3.5.
5. **One encrypted round-trip** (battery on `0x0029`): decrypts; check whether the device's
   trailer is `seq ‖ CRC` and whether its sequence numbers are its own or follow ours.
   Promotes §3.3.
6. **Chunk acks**: does the strap set `0x04` on its last chunk; does it notify acks on
   `…0016`; does anything break if the phone never acks.
7. **Time set** via `0x0047` (reply `06 01`), then read back through a fetch start reply.
8. **HEALTH config read**: record the group version and every arg value; confirm arg `0x05`
   toggles with Zepp's "Heart Rate Push".
9. **Fetch each type** in §6.5 over Path A for a 24 h window: record length rules, versions,
   first-record time vs *since*, and compare values against Gadgetbridge (or Zepp) for the
   same window. Specifically: HRV unknown byte (tz?), HRV statistic (compare to Zepp's
   displayed HRV), temperature constants, sleep-session minute base (midnight vs noon).
10. **Ack semantics**: fetch a type, ack `09`, fetch again with the same *since*: same data
    re-delivered? Then (once, on a window already validated) ack `01` and fetch again.
11. **Tier 0 live HR**: with Heart Rate Push on, connect **without** auth and subscribe to
    `0x2A37`; then with it off. Note RR-interval presence (flag bit 4).
12. **Coexistence**: with the Zepp app installed but force-quit, does it steal the
    connection? After uninstalling Zepp, does the key keep working across strap reboots?

---

## Changelog

- 2026-09-30: first version (zepp-spec agent, #215 Phase 0). All claims 🟡/🔴.
