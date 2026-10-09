# Ring-day product scope

Base: 45b8337 (PWA release). Make the ESP-WROOM-32 + collector + PWA ready for a first real RingConn Gen 2 sync, and make archived observations useful over time.

- Connection view with first-sync checklist, exact per-channel persisted evidence, recent complete syncs/uploads, protocol/page counts, metric coverage and privacy-safe support export. An upload alone is not a successful sync. Never infer BLE/Wi-Fi liveness from old data.
- Browser setup assistant creates a secrets.h file locally for the 30-pin WROOM board or C6. Validate exact ring name, optional System ID MAC, trusted-LAN HTTP collector URL, token, Wi-Fi, POSIX timezone and schedule. Credentials never enter server requests, browser storage, offline snapshots or telemetry. Config creation does not prove hardware pairing/flashing.
- Daily observations view groups all real samples by local calendar date with an explicit IANA timezone and DST-aware boundaries. Missing days remain empty; no daily step totals, sleep stages or proprietary scores are invented. Show count, observed span, mean/min/max and sources. Date selection opens that day's measurements.
- Favorites personalize summary without storing health values. Interactive metric charts expose bucket time, actual count, mean/min/max using pointer and keyboard controls with accessible labels.
- Online SQLite backup/check CLI keeps a consistent archive including raw evidence, refuses overwrite, verifies backup integrity, and never exports tokens. Document restoration and first-ring acceptance.
- Preserve read-only cookie access, API-only ingest, consent-only offline health storage, stale/empty/error semantics and complete exports. New health state must clear with logout/session expiry and only join offline snapshots with existing explicit consent.
- Test daily timezone/DST/zero/gap semantics, diagnostics (partial versus complete sync, empty channels), config escaping and validation, and consistent backups before implementation. Run all tests, Docker smoke and real Chromium desktop/mobile first-sync/daily/chart/offline/privacy interactions. Hardware and native iPhone/Safari acceptance remain separate gates until available.

No native HealthKit writes, radio commands, pairing resets, invented historical steps or inferred clinical scores in this phase. Confirm hardware model and deployment target with the owner while independent build work proceeds.
