# Device seam (#214)

A thin "any wearable" seam in front of `RingSession`, so a second device (Amazfit Helio Strap,
Zepp OS) can land as its own driver without rewriting the app. **This is not a rehaul.**
`RingSession` keeps its internals; it gains a protocol conformance in a separate file. v1 has
**one active device at a time**.

Measured on `origin/master` b1c2fdd (build 56), 2026-09-30.

## 1. Where `RingSession` is used today

`grep -rl RingSession ios/OpenCircuit` finds 29 files besides `RingSession.swift` itself.
- **12 mention it only in comments:** AppDelegate, BackgroundRefreshScheduler, EpochArchiveStore,
  RingMetadataStore, ObservabilityStore, NapEditView, EditSleepView, DayDetailView, ExportBuilder,
  SleepCardView, HeadacheEngine, HealthKitWriter.
- **17 use it in code.** 16 name the type. `RingBackgroundSyncService` reaches it through
  `scanner.session`.
- `App.swift` never names it (so the grep misses it) but reaches it through
  `RingScanner.shared.session`. That makes 18 rows below.

"Agnostic" means any wearable could answer it: connection, battery, live HR, a history sync.
"RingConn" means it depends on the RingConn wire protocol or on a ring-only feature.

| File | Members used | Kind |
|---|---|---|
| `BLE/RingScanner.swift` | Owns the session. `ready`, `syncing`, `syncHistory`, `liveHR`, `steps`, `lastFrameAt`, `startMonitoring`, `stopLiveMonitoring`, `invalidate`, `setLocalStore` · `epochArchiveStore`, `healthSleepSegments`, `isInSleepWindow`, `resumeChannelHint`, `interruptedDrainChannel`, `rediscoverIfNeeded` | Mixed. It is the RingConn transport and stays ring-only |
| `ContentView.swift` | `ready`, `syncing`, `syncStatus`, `syncHistory`, `batteryPercent`, `batteryStale`, `batteryFetchedAt`, `charging`, `inferredCharging`, `liveHR`, `liveSpO2`, `liveMode`, `monitoring`, `historySamples`, `firmwareInfo` · `caseBattery`, `batteryTTESamples`, `batteryChargeSamples`, `notStreaming`, `appearsNotWorn`, `autoMeasuring`, `liveHRWarmup`, `livePreparing`, `userMeasuring`, `userMeasureFailed(Message)`, `workoutHolding`, `calibrationCapturing`, `probing`, `probeStatus`, `probeActivityChannels`, `captureHistoricPull`, `capturingHistoricPull`, `historicPullStatus`, `captureForensicSweep`, `capturingForensicSweep`, `forensicSweepStatus`, `rawCaptureLog`, `lastFrame`, `lastDrainSummary`, `lastDrainTraces`, `lastAdoptedRecordCount`, `recorderStallEvidence`, `lastSyncAnomalies`, `lastSleepPersistOutcome`, `healthSleepSegments`, `stagedSegments`, `applySleepEdit`, `sleepEditDataCoverage`, `automaticWorkoutCandidates` | Mixed. The status card is agnostic; the RE tools, drain traces, calibration and sleep edit are RingConn |
| `VitalsTableView.swift` | `ready`, `syncing`, `monitoring`, `liveMode`, `liveSpO2`, `liveTemperature`, `liveHRTrend`, `liveReadingsStale`, `lastFrameAt`, `steps`, `historySamples`, `startMonitoring`, `stopLiveMonitoring`, `RingSession.LiveMode` · `notStreaming`, `livePreparing`, `userMeasuring`, `workoutHolding`, `probing`, `capturingHistoricPull`, `capturingForensicSweep`, `calibrationCapturing` | Mixed. On-demand HR/SpO₂ measure buttons |
| `DeviceInfoView.swift` | `ready`, `syncing`, `monitoring`, `firmwareInfo` · `sourceRingIdentity`, `setAirplaneModeOn`, `setOSAAssessment`, `osaAssessmentArmed`, `latestOSABurst`, `setAutomaticWorkoutDetection`, `automaticWorkoutDetectionEnabled`, `diagnosticsFrameCount`, `clearDiagnosticsCapture`, `repairFromRecoveredRecords`, `RingSession.diagnosticsCaptureKey` | RingConn (a ring device screen) |
| `FindMyRingView.swift` | `ready`, `ringRSSI`, `startFindingRing`, `stopFindingRing`, `setFindRingLight`, `findRingLightOn` | RingConn |
| `RingVibrationView.swift` | `ready` (it passes the session to `RingAlarmController`) | RingConn |
| `RingAlarmController.swift` | `supportsVibration`, `vibrate`, `vibrateBurst`, `lastVibrationBlock` | RingConn (Gen 3 motor) |
| `CalibrationSupport.swift` | `startPPGCalibrationCapture` | RingConn (raw PPG, `06 05 00`) |
| `CalibrationSessionView.swift` | `ready` (it passes the session to `CalibrationSupport`) | RingConn |
| `WorkoutSessionManager.swift` | `ready`, `liveHR`, `liveHRAt` · `beginSportSession`, `endSportSession`, `workoutHRActive`, `sportFrameCursors`, `sportUsingLivePollFallback`, `bufferedSportSamples`, `noteManualWorkout`, `clearManualWorkout`, `RingScanner.onSessionReplaced` | Mixed. The HR feed is agnostic; native sport mode is RingConn |
| `WorkoutView.swift` | `ready`, `syncing`, `workoutHolding` · `automaticWorkoutCandidates`, `resolveAutomaticWorkoutCandidate` | Mixed |
| `HealthNotificationCenter.swift` | `isLinkConnected`, `lastFrameAt`, `charging`, `historySamples` | Agnostic |
| `Observability/ActivityLogView.swift` | `firmwareInfo`, `lastSyncAnomalies` | RingConn (firmware-mismatch banner, decode anomalies) |
| `Diagnostics/DiagnosticsReport.swift` | `firmwareInfo`, `frameCaptureReport`, `diagnosticsFrameCount`, `archivedEpochs` | RingConn |
| `Background/RingBackgroundSyncService.swift` | `refreshNightWindowIfNeeded` (via `scanner.session`) | RingConn |
| `App.swift` | `RingScanner.shared.session` → `RingAlarmController.evaluate` | RingConn |
| `UserProfile.swift` | `RingSession.autoMeasureEnabledKey` (static) | RingConn setting key |
| `Store/LocalStore.swift` | `RingSession.lastNotifiedNightKey` (static) | Agnostic key that happens to live on `RingSession` |

**What this says:** the device-agnostic surface is small, and every view already uses it through
the same member names: connection (`ready`, `isLinkConnected`, `lastFrameAt`), battery
(`batteryPercent`, `charging`), live HR (`liveHR`, `liveHRAt`, `steps`) and history
(`syncing`, `syncStatus`, `syncHistory`). Everything else is the RingConn protocol surfacing in
UI. HealthKit writes had no `HKDevice`: `grep -rn HKDevice ios` returned 0.

## 2. The seam (Part A, no schema change)

| Piece | Where | Notes |
|---|---|---|
| `WearableDeviceKind`, `WearableCapabilities`, `WearableIdentity`, `HealthDeviceFields` | `OpenCircuitKit/Wearable.swift` | Pure value types with no Apple frameworks. Tested by `WearableTests` |
| `protocol WearableSession` | `ios/OpenCircuit/Wearable/WearableSession.swift` | `@MainActor`, `AnyObject`, `Observable`. It stays in the app target because Observation needs macOS 14 and the Kit manifest declares no platforms; editing `Package.swift` would collide with the Zepp targets |
| `extension RingSession: WearableSession` | `ios/OpenCircuit/BLE/RingSession+Wearable.swift` | Three computed properties. Everything else is satisfied by existing members |
| `ActiveWearable`, `WearableIdentityStore` | `ios/OpenCircuit/Wearable/ActiveWearable.swift` | `@Observable` holder of "the active `WearableSession`". Always the ring in v1. Injected once in `App.swift` |
| `HKDevice` attribution | `HealthKitWriter` | Mapping is `HealthDeviceAttribution.fields(for:origin:)` (Kit, tested) → `HKDevice` |

**Protocol members reuse `RingSession`'s existing names on purpose** (`ready`, `syncing`,
`batteryPercent`, `liveHR`, …). When a view is later retyped from `RingSession?` to
`(any WearableSession)?`, none of its agnostic call sites change, so the diff shows only the
type change. It is also why the conformance is three properties and not a wrapper.

**The one edit inside `RingSession.swift`** is a one-line accessor, `peripheralIdentifier`, next
to `isLinkConnected`. `peripheral` is `private` (file scope), so no extension in another file can
read the ring's stable id. Nothing is moved or restructured.

**Capabilities.** The brief's minimum set, plus what the table shows ring-only UI depends on:
`airplaneMode`, `sleepApneaAssessment` (OSA arming), `automaticWorkoutDetection`,
`nativeWorkoutMode` (sport mode `0x4e`), `diagnosticsCapture` (raw-frame capture, repair
import, RE probes). A RingConn ring's set is a pure function of its generation
(`WearableCapabilities.ringConn(generation:)`) and mirrors the gates the UI already applies:
- `vibration` and `alarm` are Gen 3 only, `RingVibration.isSupported`. This fails closed while
  the generation is unknown.
- `sleepApneaAssessment` is withheld only from a positively identified Gen 2 Air (#186). It fails
  open, like `DeviceInfoView.sleepApneaUnavailable`.

Data the UI shows only when present (`caseBattery`, `liveTemperature`) gets no capability; the
UI already gates it on the data itself.

**Capability gating in views: none in this PR, on purpose.** Every view with ring-only UI is typed
`RingSession?`, so `session?.capabilities.contains(.findMyDevice)` inside it is always true for a
ring and never reached by any other device. It would be a tautology that can't change behaviour
and can't be tested, and it adds merge surface next to the parallel dashboard work. Each gate
becomes a real one-liner in the PR that retypes its view (follow-ups §4).

### Identity and `HKDevice` field mapping

| `HKDevice` | From `WearableIdentity` | RingConn value |
|---|---|---|
| `name` | `displayName` (`name ?? manufacturer`) | Model family, e.g. "RingConn Gen2". The advertised name's MAC suffix is stripped by `RingMetadataStore.modelFamily`, the same privacy rule the export uses |
| `manufacturer` | `manufacturer` | "RingConn", the brand, from the device kind. DIS 0x2A29 reads `JZ_Tech` (the OEM, PROTOCOL.md §1) and stays on the Device Info screen |
| `model` | `model` | Generation label ("Gen 2", "Gen 2 Air", "Gen 3"), or nil while unknown. Never "Unknown" |
| `hardwareVersion` | `hardwareVersion` | DIS 0x2A27 |
| `firmwareVersion` | `firmwareVersion` | DIS 0x2A26, e.g. "FR02.018" |
| `localIdentifier` | the family's sync timeline, `SyncDeviceID.timeline(for: kind, identityID: id)` | `"ringconn"` for every RingConn ring (Juan's decision: all rings are one device, as they are one store timeline, §3). A Zepp OS device gets `zeppos:<id>` by the same rule. Never the MAC |
| `softwareVersion`, `udiDeviceIdentifier` | none | nil |

Empty strings map to nil, so no field is ever written as "".

**Consistency across connection states.** Apple Health lists one device per distinct `HKDevice`.
A flush can run while the ring is connected (all DIS fields known) or in a cold background
launch before it connects (the fields are unknown). If each write used whatever happened to be
known at that moment, one ring would show up as several devices. So `ActiveWearable` persists the
last identity per device id (`WearableIdentityStore`, UserDefaults, no schema). It merges live
fields over the persisted ones with `WearableIdentity.merging(previous:)`: a known field is never
downgraded to unknown for the same id, and a different id never inherits another ring's fields
(the rule `RingMetadataStore.record` already uses). When no session exists, the persisted identity
of the active ring (`RingScanner.activeRingID`) is used, falling back to the last-connected ring's
id in `RingMetadataStore`. The store stays keyed per peripheral even though every ring shares the
`localIdentifier` "ringconn": one ring must never report another's firmware.

**Before the ring has identified itself, a write names no device.** With nothing persisted for a
ring and no firmware version read yet (the DIS read is still in flight on its first connection),
`identityForHealthWrite()` returns nil and records nothing. The sample is written device-less,
exactly as before the seam, instead of naming the ring with its name only. Without this, Health
would list one ring twice: once as that sparse first identity and once in full.

**Which samples carry the device.** Everything the wearable measured or that is derived from its
data: HR, HRV, SpO₂, RR, temperature, steps, distance, resting HR, active and basal energy,
measured sleep, and the BP estimate (the correlation and both components). **Not attributed:**
samples a person entered, which are headache and menstrual-flow logs plus sleep spans written
with `HKMetadataKeyWasUserEntered: true` (asserted spans and manually added naps). HealthKit's
own semantics for user-entered data is "not from a device", and the app's provenance model
(measured vs asserted) depends on keeping them apart. This is a deliberate narrowing of "every
sample" and an open question for Juan (§5). Flipping it is one line in
`HealthDeviceAttribution.fields(for:origin:)`.

**Not changed:** `WorkoutSessionManager` builds its workout with `HKWorkoutBuilder(device:
.local())` (the iPhone) and its route with `device: nil`. It is outside `HealthKitWriter`, and
re-attributing workouts is a visible Health change of its own (follow-ups §4).

## 3. Store (Part B, schema change: SchemaV8)

**The bug.** `StoredCursor` was unique per `kindRaw` and `StoredSample` had no device column.
`SyncCursor.selectNew` drops every sample at or before the kind's single watermark, so a second
device's backfill that is older than the ring's watermark was silently discarded. The `hk:` Health
watermark had the same shape, so even a stored backfill would never have reached Apple Health.

**The change.**

| | Before (V7, b47–b56) | After (V8) |
|---|---|---|
| `StoredSample` | no device | `deviceID: String = "ringconn"` |
| `StoredCursor` | `@Attribute(.unique) kindRaw` = the cursor name | same unique column, now the **(device, name) key**, plus `deviceID: String = "ringconn"` |
| Cursor key | `heartRate`, `hk:heartRate`, `export:…` | ring: **unchanged**. Another device: `<name>@<device>` (`SyncCursorKey`), so `hk:`/`export:` prefixes still filter |
| Migration | | `.lightweight(V7 → V8)`: two defaulted columns. **No key or value changes**; Core Data back-fills the default into every existing row in place (O(rows), measured 0.7 s per 1M rows on the simulator) |

`#Unique` is iOS 18 and the deployment target is 17. Uniqueness therefore stays the one
`@Attribute(.unique)` string the table already had, and that string now carries the device.
Renaming the column (`originalName:`), or a custom stage that rewrote every key, would each have
added a failure mode to a migration whose failure path deletes raw history (build 44). The ring's
keys staying byte-identical is what keeps the stage lightweight.

**Legacy device id: a documented constant, `SyncDeviceID.ringConn` = `"ringconn"`, not the
persisted active-ring id.** Why:
1. **The store's device dimension is a timeline, not a peripheral.** Multi-ring has always been
   sequential with a merged timeline (`RingScanner`: "no per-ring data segregation"). If each
   ring's peripheral UUID were the store device, the ring you swap to would start with an empty
   cursor. It would re-admit everything still on it and re-write it to Apple Health, which is a
   behaviour change for ring users. Every RingConn ring therefore maps to `"ringconn"`
   (`SyncDeviceID.timeline(for:identityID:)`), and a Zepp device maps to `zeppos:<id>`.
2. **The persisted active-ring id isn't reliably available inside the stage.** It lives in
   UserDefaults (`com.opencircuit.ring.activePeripheralID`). It is nil after an explicit
   disconnect, and a lightweight stage can only apply a static column default. Using it would mean
   a custom stage that reads outside the store mid-migration.
3. It is a literal default, so the migration is a pure schema diff. The value is pinned by
   `SyncDeviceTests.testTheRingTimelineIdIsPinned` and by the migration tests asserting every
   migrated row reads `SyncDeviceID.ringConn.rawValue`, through the getter and in the SQL column
   itself (`testABuild56StoresDeviceColumnIsRingconnInSQLOnEveryMigratedRow`; the b33, b43 and b45
   arms walk the whole chain to V8 and check the same).

**Every cursor read/write, per device, defaulting to the ring.**
- `ingest`, `previewIngest`, `loadCursor`: only that device's rows, via `SyncCursor.forDevice`.
- `cumulativeState`: a step delta is never taken against another device's raw counter.
- `pendingHealthSamples`, `markHealthWritten`, `loadHealthCursor`: the `hk:` watermark is per device.
- `repairFutureSyncCursors`: resets a row to its own device's latest sample.
- `upsertCursor(name:last:device:)`: takes the cursor NAME and builds the unique key from the same
  device it labels the row with, so a key and a device can never disagree.

`SyncCursor.selectNew` itself is unchanged; what changed is that the cursor it runs on belongs to
one device. **Every existing caller passes no device**, so the ring reads and writes exactly the
rows and keys it did before. The app-target suites for this code (`CaptureToStoreEndToEndTests`,
`HealthWatermarkTests`, `SyncCursorPlausibilityTests`) had crashed on every run because of a
container-lifetime bug in their harness. They were fixed first (test-only) and pass 16/16 both
before and after the store change.

**Not in this change (Helio driver PR):** `HealthKitWriter.flushToHealth` still mirrors the ring's
timeline only, because its call sites are unchanged. The Helio PR adds its device to that pass
(`pendingHealthSamples(device:)` / `markHealthWritten(_:device:)` already exist). Dashboard reads
(`samples(kind:…)`, Trends) stay device-agnostic, which is correct while v1 has one active device.

**Gates** (`docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md`):
- Gate A is `-only-testing:OpenCircuitTests/ShippedStoreMigrationTests` with the executed count
  checked. It now also opens a genuine b56 (V7) store.
- Gate B is an on-device upgrade from a pre-45 build, and it is Juan's.

**V8 is forward-only.** Once a build carrying SchemaV8 has shipped, recovery is forward-only. Any
later build, including a revert of #218, must keep `SchemaV8` and the V7→V8 stage in
`MigrationPlan`. To drop `deviceID`, add a V9 and never remove V8. Never tell testers to reinstall
a build ≤ 56. Why: a build that doesn't know V8 can't open a V8 store. Its staged migration throws
`NSCocoaErrorDomain 134504` ("Cannot use staged migration with an unknown model version"), the app
catches that in `resolveContainer` and goes to `wipeAndRecoverForeground`, and every
`StoredSample`, `StoredCursor`, `StoredStepSample` and `StoredDaytimeTemp` row is deleted on every
phone that ever launched a V8 build. `ShippedStoreMigrationTests.testABuild56PlanCannotOpenAMigratedStore`
pins the throw.

## 4. Follow-ups (not in this PR)

1. **Retype views to `(any WearableSession)?` and gate ring-only controls.** One line per gate:
   - `DeviceInfoView` Find My Ring → `.findMyDevice`.
   - Vibration row → `.vibration`: replace `RingVibration.isSupported(info.generation)` with
     `session?.capabilities.contains(.vibration) == true`. They are equivalent by construction.
   - Airplane mode → `.airplaneMode`.
   - OSA toggle → `.sleepApneaAssessment`.
   - Automatic workout detection → `.automaticWorkoutDetection`.
   - ContentView calibration section → `.bloodPressureCalibration`.
   - ContentView RE tools / `DeviceInfoView` diagnostics → `.diagnosticsCapture`.
   - VitalsTableView measure buttons → `.onDemandHeartRate` / `.onDemandSpO2`.

   `DeviceInfoView`, `FindMyRingView`, `RingVibrationView`, `CalibrationSessionView` and
   `DiagnosticsReport` are ring device screens; the Helio gets its own screen rather than a branch
   inside these.
2. **`WorkoutSessionManager`**: move native sport mode (`beginSportSession`/`endSportSession`, sport
   frame cursors) behind `.nativeWorkoutMode`, with a live-HR-only fallback for devices without it.
   Decide whether workout samples keep `device: .local()` or name the wearable.
3. **`RingScanner` → device registry.** Typed saved devices (`.ringConn(model)` / `.zeppOS(model)`)
   with a Keychain key ref per Zepp device. `ActiveWearable.session` then picks between drivers
   instead of reading `RingScanner.shared.session`.
4. **Static keys on `RingSession`.** `lastNotifiedNightKey` is device-agnostic and belongs somewhere
   else (e.g. `HealthNotificationCenter`), but moving it changes nothing today, so it is left alone.
5. **Samples flushed after a ring swap** are attributed to the ring active at flush time. They
   share its `localIdentifier` ("ringconn"), so Health still lists one device; only the name and
   versions on those samples can be the newer ring's. Resolving each row's `HKDevice` from its own
   device is a follow-up once a registry holds more than one identity.

## 5. Open questions for Juan

1. User-entered samples (headache, menstrual flow, asserted/typed sleep) are **not** given the
   ring's `HKDevice` (§2). OK, or do you want literally every sample attributed?
2. `manufacturer` = brand ("RingConn") rather than the DIS string (`JZ_Tech`). OK?

## 6. The second device (Helio Strap, #215 phase 3)

- `ActiveWearable.session` now reads the device `ActiveDeviceChoiceStore` names:
  `RingScanner.shared.session` or `HelioConnection.shared.session`. Only the chosen driver is read,
  so the other is never constructed by it. The ring stays the default.
- `HealthKitWriter.flushToHealth` gained the strap's pass (`device:`, `mirroredKinds:`,
  `strapNights:`); `LocalStore.pendingHealthSamples` gained a `kinds:` filter. Their defaults are
  the ring's pass, byte for byte.
- No view was retyped to `(any WearableSession)?`: the strap got its own screens
  (`ios/OpenCircuit/Helio/`), and `ContentView` hides the ring-only surfaces while the strap is
  chosen (its `session` is nil then). Follow-up §4 item 1 still stands for the ring's views.

