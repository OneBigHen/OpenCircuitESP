# RingConn Gen 2 — ESP32 local bridge

A standalone home-lab companion inside this [OpenCircuit fork](https://github.com/OneBigHen/OpenCircuitESP). The iOS code is left untouched. This bridge is independently implemented using the [upstream RingConn protocol research](https://github.com/perezjuanj/OpenCircuit/blob/master/docs/PROTOCOL.md).

**Current stage: software prototype. Gen 2 device synchronization is NOT yet hardware-tested.** Do not uninstall the RingConn phone app or erase its history before comparing several live downloads.

## Hardware

- **ESP32-WROOM-32 / generic DevKit:** `esp32dev` build target (default).
- **AITRIP Type-C 30-pin CP2102 ESP-WROOM-32 / ESP-32S:** use `esp32dev`;
  see [the board-specific flashing guide](FLASHING.md).
- **ESP32-C6 DevKitC-1:** `esp32c6` build target.
- USB power, a stable 2.4 GHz Wi-Fi network, and proximity to the ring are required.
- Both require a **minimum 4 MB flash board**; the custom partition table has one 2 MB app slot and a 1.94 MB LittleFS spool. **This layout has no OTA slot**; flash firmware via USB. Do not change the partition layout on a board holding data without backing up the spool first.
- Both use **pioarduino's maintained Arduino 3.x PlatformIO platform**, pinned to
  55.03.312 with NimBLE 2.5.1. Install **PlatformIO Core 6.2.0 or newer**.
  Both binaries are built in GitHub Actions.

## Architecture

```
RingConn Gen 2
    └─ BLE  → ESP32 NimBLE central (scan, bond, SM3 challenge, channels 0x00 + 0x03)
              └─ LittleFS persistent raw-frame spool (save + flush BEFORE ACK)
                   └─ HTTP POST to LOCAL collector → SQLite
                                                     └─ /status and /history
                                                          └─ HA REST sensors / dashboard
```

When the collector is unavailable, the ESP32 preserves ACKed history in flash and refuses additional history if capacity runs low. Only a committed collector response clears the spool.

## Set up local collector (Docker host or Proxmox LXC)

```bash
cd esp32_bridge
cp .env.example .env
# Put a long random token in RING_TOKEN (e.g. openssl rand -hex 32).
docker compose up -d --build
curl http://YOUR_SERVER_LAN_IP:8765/health
curl -H 'X-Ring-Token: YOUR_TOKEN' http://YOUR_SERVER_LAN_IP:8765/status
```

Docker stores data in `esp32_bridge/storage/ringconn.db`; back this directory up. Port 8765 is **LAN-only**. Do not forward it to the internet. Transport is unencrypted HTTP; use a trusted/private VLAN or HTTPS reverse proxy if traversing untrusted networks.

## Flash an ESP32 (PlatformIO CLI)

```bash
cd esp32_bridge/firmware
cp include/secrets.h.example include/secrets.h
# Configure WIFI_SSID, WIFI_PASSWORD, COLLECTOR_URL (LAN IP), COLLECTOR_TOKEN.
# Configure the ring's EXACT advertised RING_NAME; optionally RING_MAC.
pio run -e esp32dev -t upload    # WROOM-32
# OR
pio run -e esp32c6 -t upload     # C6 DevKitC-1
pio device monitor -b 115200
```

To discover your RingConn Gen 2's exact Bluetooth advertisement name, initially flash with the placeholder RING_NAME, keep the ring nearby, and read `Nearby BLE: NAME [address]` in the serial monitor. The placeholder does not match or connect. Then set RING_NAME, optionally RING_MAC (system ID MAC, not necessarily BLE advertisement address), and flash again.

**Phone connection:** Temporarily disable Bluetooth access for the RingConn app during initial tests so the two centrals don't compete. Do not factory-reset the ring just to pair the bridge.

## Automatic behavior

- Starts a 6-second scan approximately every 15 minutes.
- Tries only the exact configured advertisement name; if RING_MAC is specified, also checks the ring's reported System ID.
- Connects, bonds, subscribes to notifications, performs SM3 authentication, drains overnight/sleep channel `0x00` and all-day channel `0x03`.
- Stores every history page `0x47`/`0x4c` before acknowledging it, and stores `0x50` cursor end markers.
- Discards optional high-volume `0x48` OSA waveforms (not yet supported).
- After a complete upload, waits 8 hours; default normal scan/sync window is 9 AM–10 PM ET (editable).
- Requires **both channels' persisted end markers** (or explicit empty-channel ACKs) before marking a sync successful. The collector exposes `last_complete_sync` separately from `last_upload`.
- Completion markers must belong to the current attempt; previous attempts cannot
  supply a missing channel. Update collector and firmware together.
- On reboot/upload, an interrupted final spool record is archived in
  `pending.ndjson.torn`, then complete records are recovered through a synced
  temporary file and atomic rename. UnACKed tail bytes are never ingested.
  Startup only formats a completely erased filesystem partition.
- Stores the last successful sync in NVS to avoid aggressive reconnects after reboots.

## Home Assistant

Merge the example `homeassistant/rest.yaml` into your `configuration.yaml` (one top-level `rest:` block), replace the host IP and set `ringconn_token` in `secrets.yaml`. Use `homeassistant/dashboard.yaml` as a starting dashboard.

### Accuracy boundaries

- Downloaded historical heart rate, sleep-context HRV (RMSSD), SpO₂ and respiratory rate are decoded from the 23-byte 0x4c epochs.
- Temperature/battery are from **live** status reads. They cannot be backfilled from old sleep epochs.
- The step counter is a **current quarter-hour bucket**, not total daily steps. The bridge does not invent totals.
- No fabricated proprietary sleep stages, recovery score, or per-minute SpO₂.
- The 24-bit epoch timestamp currently uses the closest time window, not a complete `0x50` cursor replay; verify unusually old backlogs.
- If hardware, firmware, or radio behavior differs, raw frames are preserved for debugging.

## Test & CI

```bash
g++ -std=c++17 -Wall -Wextra -Iesp32_bridge/firmware/include esp32_bridge/firmware/src/ring_protocol.cpp esp32_bridge/tests/native_protocol_test.cpp -o /tmp/ringtest
/tmp/ringtest
g++ -std=c++17 -Wall -Wextra -Werror -Iesp32_bridge/firmware/include esp32_bridge/firmware/src/spool_recovery.cpp esp32_bridge/tests/native_spool_test.cpp -o /tmp/spooltest
/tmp/spooltest
python3 -m unittest discover -s esp32_bridge/tests -p 'test_*.py' -v
```

GitHub Actions builds WROOM and C6 separately, plus host-side protocol and SQLite tests. Download build artifacts from the workflow once green. **CI success is not evidence that the ring has been tested over BLE.**

## A/B acceptance criteria before switching off the official app

1. Correct ring is discovered; SM3 challenge is accepted, and notifications arrive.
2. Both history channels finish; `0x50` termination reported.
3. SQLite has new raw frames and plausibly decoded measurements with correct timestamps.
4. RingConn official app and bridge display consistent heart rate/HRV/SpO₂ for matching time periods.
5. Power-cycle ESP32 and disconnect Wi-Fi; confirm backlog survives and eventually uploads without duplicates.

No GitHub secrets or health measurements are required in source control.

## Local data export and accurate history

The collector keeps the **real per-epoch timestamps** (not merely the periodic 5-minute Home Assistant state changes). For your whole archive, use authenticated CSV export:

```bash
curl -H 'X-Ring-Token: YOUR_TOKEN' \
  'http://YOUR_SERVER_LAN_IP:8765/export.csv?device=AA:BB:CC:DD:EE:FF&since=0' \
  -o ringconn-measurements.csv
```

The `/history?device=...&metric=hr_bpm&since=...` API returns at most 5,000 chronological points (set `limit=...`). The Home Assistant REST sensors show the **latest observation**, becoming unknown when too stale (24–36h), and do not backfill all 2.5-minute historical records into HA Recorder. SQLite/CSV preserves those records for long-range analytics.

**Caution:** changing the partition table on an already flashed ESP32 may erase LittleFS. Do not change the flash layout after collecting ring history without first uploading and backing it up.
