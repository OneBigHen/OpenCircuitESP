# OpenCircuit Health PWA

Build an installable, local-first companion to the ESP32 collector. The first
release serves one household's collector, with a ring selector when several
devices exist. It is not an account system or an Apple Health replacement.

Acceptance scope:

- A calm mobile and desktop summary, vitals, trends and connection/settings views.
- Every decoded metric has its units, provenance, observation time and gaps.
  Unavailable and stale observations are explicit; quarter-hour steps never
  become fabricated daily totals. Sleep stages, stress and recovery scores are
  labeled unsupported, not populated with estimates.
- Day/week/month/year and custom date ranges, aggregate charts over the entire
  selected range, previous-period comparisons, paginated exact samples, CSV.
- Read-only browser sessions in HttpOnly/SameSite cookies; token stays out of
  browser storage. Cookie sessions cannot ingest frames or confirm a sync.
- Install manifest, offline app shell, optional explicitly enabled local data
  snapshots, and logout/clear-device-data controls. Service worker never caches
  health API responses or credentials. No analytics or external runtime assets.
- Desktop/mobile browser QA, authenticated/empty/error/offline/stale data states,
  meaningful API/model regressions, and Docker packaging verification.

Physical ring acceptance remains a separate gate. Public HTTPS deployment must
protect health endpoints and use secure cookies; raw LAN HTTP is not sufficient
for installing a PWA on a phone. iOS installation is tested separately from
browser emulation. Apple Health read/write would require the native companion.
