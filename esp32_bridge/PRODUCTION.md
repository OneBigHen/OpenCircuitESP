# RingConn bridge: production notes

## Moving parts
- **ESP32 bridge** (hard-powered, near the ring/case): holds one authenticated BLE link to the ring and
  asks for its status every 15 s; does full history syncs every 8 h; uploads to the collector over LAN HTTP.
  Flash holds a spool, so a collector outage loses nothing. Hang watchdog (10 min) and a weekly idle restart.
- **Collector** (Docker, or the Home Assistant add-on): SQLite archive, health page, `/status` API.
- **Home Assistant**: `homeassistant/ringconn_package.yaml` + `ringconn_dashboard.yaml`, using the
  read-only `RING_HA_TOKEN`.

## Where to run the collector
1. **docker-stable (recommended).** Separate from HA, simple to restart, the compose file is hardened
   (non-root, read-only root, no capabilities, memory/pid limits, healthcheck, log rotation).
2. **Home Assistant add-on.** Same code, backed up inside HA's own backups (cold backup). Build it with
   `deploy/ha_addon/build.sh`, copy `deploy/ha_addon/dist/ringconn_collector` to HA's `/addons/` folder
   (Samba share `addons`), then install it from Local add-ons. No separate HA OS VM is needed; HA is already HA OS.
Run only one at a time.

## Stability gate before migrating
Migrate only when all of these hold: a full sync has completed (`last_complete_sync` set), in-case and
out-of-case transitions have been seen in `/status` (`in_case` flips), the HA sensors and automations have run
for a few days without surprises, and the bridge has gone a week without a watchdog or Wi-Fi reset
(check `/diag` for `reset=` values).

## Migrate to docker-stable
1. `deploy/migrate-to-docker-stable.sh --yes` from the docker-dev checkout. It snapshots the live archive,
   copies the collector and keys to `docker-stable:/srv/ringbridge`, starts it, runs the integrity check and
   installs a daily backup timer. The old collector keeps running.
2. Failover without reflashing: build the firmware once with
   `#define COLLECTOR_URL_FALLBACK "http://192.168.1.175:8765"` in `secrets.h` (already the default plan).
   When the primary (docker-dev) stops answering the bridge switches to the fallback by itself.
3. Cut over: stop the docker-dev collector (`docker compose stop`). Within a minute the bridge uploads its
   spool to docker-stable. Confirm `/status` on `192.168.1.175:8765` shows fresh frames.
4. Point Home Assistant at the new host: edit the `resource:` URL in `packages/ringconn.yaml` to
   `http://192.168.1.175:8765/status` and reload (or restart) HA. The read-only key is unchanged.
5. Later, make docker-stable the primary in `secrets.h` (one USB reflash through the Pi) and remove the old one.
Rollback: `docker compose start` on docker-dev; the bridge fails back automatically.

## Operations
- Backups: `deploy/backup.sh` (SQLite online backup, 14 kept) via `ringbridge-backup.timer` at 04:20.
  Also copy `/srv/ringbridge/storage/backups` off the host on a schedule (it is health data; keep private).
- Updates: `git pull && docker compose up -d --build`. Restore steps are in README.md.
- Rotate keys: change `RING_TOKEN` / `RING_HA_TOKEN` in `.env`, restart the collector, update `secrets.h`
  (reflash) and HA's `secrets.yaml` to match.
- Firmware updates: USB only (no OTA slot). App-only flash at `0x10000` keeps the spool and settings.
- Watch: `sensor.ringconn_last_frame_age` (stale while the ring is in the case or out of range is normal),
  `sensor.ringconn_sync_health`, and `/diag` for resets.
