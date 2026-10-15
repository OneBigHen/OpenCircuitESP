# RingConn Collector

Receives the ESP32 bridge's uploads, stores them in SQLite (`/data/ringconn.db`, included in Home
Assistant backups) and serves the health page on port 8765.

## Options
- **ring_token** (required): random string of 20+ characters. The ESP32 firmware's `COLLECTOR_TOKEN`
  must match it. Only this key can ingest data.
- **view_token** (optional): separate key for signing in to the health page.
- **ha_token** (optional): a different random key that can only read `/status` (for Home Assistant's
  REST sensors; store it as `ringconn_ha_token` in `secrets.yaml`).
- **secure_cookie**: leave off for plain-HTTP LAN use; turn on only behind an HTTPS proxy.

## Home Assistant sensors
Point the package's REST resource at `http://local-ringconn-collector:8765/status` when running as an
add-on (or the host's LAN IP).

## Backups
The add-on is backed up "cold" (stopped during the backup) so the database is consistent.
