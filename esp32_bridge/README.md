# RingConn Gen 2 — ESP32 local bridge

A standalone home-lab companion inside this [OpenCircuit fork](https://github.com/OneBigHen/OpenCircuitESP). The iOS code is left untouched. This bridge is independently implemented using the [upstream RingConn protocol research](https://github.com/perezjuanj/OpenCircuit/blob/master/docs/PROTOCOL.md).

**Current stage: software prototype. Gen 2 device synchronization is NOT yet hardware-tested.** Do not uninstall the RingConn phone app or erase its history before comparing several live downloads.

## OpenCircuit Health PWA

The collector now serves an installable health journal at `/`. It includes a
summary, all ten decoded measurements, day/week/month/year/custom ranges,
aggregate charts with visible gaps, previous-period comparisons, exact reading
pagination, CSV exports, ring selection, light/dark appearance and °C/°F.
The app uses your collector's records; it ships no demo health data.

Sign in with a private `RING_VIEW_TOKEN` if set, or the collector's `RING_TOKEN`.
An HttpOnly/SameSite cookie provides a read-only, 12-hour browser session.
The browser never stores the access key. Signing out revokes the session and
clears optional offline health snapshots; restarting the collector expires all
browser sessions. Session cookies cannot ingest frames or confirm synchronization.

Use a **private HTTPS origin** for phone installation and keep
`RING_SECURE_COOKIE=1` (the default). A reverse proxy must forward the original
Host header. Verify the login response has `Secure; HttpOnly; SameSite=Strict`
and protect the origin from direct public access. Do not publish port 8765 to
the internet. HTTPS secures browser transport; it does not make the ESP32's
local HTTP upload encrypted. Keep that path on your trusted LAN/VLAN.

For deliberate browser testing over a LAN HTTP address only, explicitly set
`RING_SECURE_COOKIE=0`; phone PWA installation/offline workers require HTTPS.
The existing ESP32/header-token APIs work independently of browser cookie mode.

On iPhone, use Share → Add to Home Screen; on supported desktop/Android
browsers use Install. The service worker caches only public app assets, never
health APIs or credentials. Offline health snapshots are off by default and
require consent in Settings. Clearing them or signing out removes the local
copy. An offline sign-out clears health data immediately and queues server
session revocation for reconnection.

Missing measurements remain unavailable, old observations are labeled, and
step buckets are not summed into daily totals. Proprietary sleep stages,
stress/recovery scores and Apple Health read/write are not implemented by the
PWA. RMSSD is not Apple's SDNN HRV. Apple Health integration requires native
iOS work; physical ring acceptance remains the checklist below.

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
node --test esp32_bridge/tests/pwa_model.test.mjs
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

## Ring-day dashboard

Open the collector's root URL and sign in with its ingest token or a dedicated
`RING_VIEW_TOKEN`. The **Connection** tab shows archived channel terminations,
complete syncs, recent uploads and measurement coverage. These describe stored
transport evidence; they are not a live BLE or Wi-Fi probe. Export sync diagnostics
for counts/timestamps without health values, raw frames, tokens or a full ring ID.

The **Setup** assistant generates `secrets.h` locally for your AITRIP 30-pin
ESP-WROOM-32 (`esp32dev`) or C6. Use the collector's trusted-LAN HTTP **root** URL,
your ingest token, and the exact ring advertisement name from USB serial scanning.
Do not enter a read-only viewing key as the ingest token. Password/token fields
clear after download; the form does not save or send them. Save the file under
`firmware/include/`, build and flash via USB. POSIX timezone presets cover US zones
and UTC; edit `LOCAL_TIMEZONE` locally for other zones. The PWA uses your browser's
IANA timezone for daily views independently of the firmware sync schedule.

**Daily** groups all stored measurements by DST-aware local calendar dates and
shows averages, ranges, observation counts/times and sources. Blank days remain
blank. Charging summaries report observed state counts, not charging duration.
Step-bucket averages are not daily step totals or distance. Tap **Open day** to
explore that day's readings. Large ranges show 30 days initially; **Show earlier
days** reveals more without truncating the query. Metric charts support tap/pointer
inspection and left/right/Home/End keys. The guide line identifies the nearest
recorded bucket, including its count, mean and range; exact samples remain below.
Choose your summary favorites in Settings; only metric names are persisted.

## Consistent archive backups and restore

Use SQLite's online backup API rather than copying a live database and ignoring
its WAL file. The backup includes raw frames, epochs, measurements and sync evidence.
It creates a private mode-0600 file, checks integrity and refuses to overwrite an
existing destination. Run from `esp32_bridge`:

```bash
# Check the live archive on its owning collector.
docker compose exec ringconn-collector python /app/archive_tools.py check --database /data/ringconn.db
# Collector stays running while SQLite takes a consistent snapshot.
docker compose exec ringconn-collector python /app/archive_tools.py backup --database /data/ringconn.db --output /data/backups/ringconn-2026-10-09.db
# Local alternative when operating directly on the same host:
python3 collector/archive_tools.py backup --database storage/ringconn.db --output storage/backups/ringconn-2026-10-09.db
```

Keep backups private; they contain health data. Choose a new destination name for
each backup and retain a copy on another protected disk. To restore a chosen backup,
first validate and stage it, **then stop the collector before replacing its files**:

```bash
set -e  # Stop this restore sequence if any command fails.
python3 collector/archive_tools.py check --database storage/backups/ringconn-2026-10-09.db
# Continue only if the command succeeds and integrity is "ok".
cp storage/backups/ringconn-2026-10-09.db storage/restore-candidate.db
chmod 600 storage/restore-candidate.db
docker compose stop ringconn-collector
mkdir -m 700 storage/pre-restore-2026-10-09
# Preserve the old database and any WAL/SHM together for rollback.
for file in storage/ringconn.db storage/ringconn.db-wal storage/ringconn.db-shm; do
  if [ -f "$file" ]; then mv "$file" storage/pre-restore-2026-10-09/; fi
done
mv storage/restore-candidate.db storage/ringconn.db
python3 collector/archive_tools.py check --database storage/ringconn.db
# Continue only after the restored integrity check succeeds.
docker compose up -d ringconn-collector
curl http://127.0.0.1:8765/health
```

Read back authenticated `/status` and the PWA's Connection/Daily views after
restoring. Never reuse the old WAL/SHM with the restored database. If validation
fails, keep the collector stopped and restore the preserved original database
and its matching sidecars from the rollback directory. The backup CLI does not
reset or operate the ring.
