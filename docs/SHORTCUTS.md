# Shortcuts actions for the wearable (#260, decision 52)

iOS lets no app see other apps' notifications or the Clock app's alarms (`ZEPP_PROTOCOL.md` §13.3),
so OpenCircuit can't relay them itself. Shortcuts personal automations are the bridge: an automation
reacts to the event, and runs one of OpenCircuit's actions.

| Action | What it does | Devices |
|---|---|---|
| **Vibrate Wearable** (Times 1–5, default 1) | Buzzes the wearable in use that many times, with a short gap. The strap's buzz is a find-device start and its stop (§13.2; decision 19, 2 s). The action returns only after the stop (`06`) was sent, plus 0.5 s for it to leave the radio. | Strap; a RingConn Gen 3 (decision 52g: the saved ring's standing connect, then up to 15 s for a ready, idle session). |
| **Set Wake Alarm on Wearable** (Time, Repeat: once by default) | Stores ONE alarm on the strap itself, which then fires it on its own (§12: 60 s of vibration, tap to stop, 🟡 Amazfit's own documentation, not yet observed by us), with no phone needed at wake time. Only the time's hour and minute are used. | Strap: stored on the strap. RingConn Gen 3: sets OpenCircuit's own ring wake-up alarm (Profile ▸ Device Info ▸ Vibration & alarm), which the app buzzes at the time; nothing is stored on the ring (see "The ring" below). |
| **Clear Wake Alarm on Wearable** | Strap: deletes that one alarm, only while it is still as OpenCircuit wrote it. Ring: turns the app's ring alarm off, only while it still holds what Shortcuts set. | Strap; RingConn Gen 3. |

The actions run in the background (`openAppWhenRun = false`) and on a locked phone
(`authenticationPolicy = .alwaysAllowed`): they disclose no health data. Every name and dialog comes
from the active device's descriptor (`ActiveDeviceChoice.onDemandVibration`, `.wakeAlarm`, decision 51e).

## Example automations (unverified: not yet tried on a phone)

The Shortcuts menu names below are iOS's, written from memory, not from a source; check them on the phone.

**Buzz for messages from one person.** Shortcuts ▸ Automation ▸ New Automation ▸ Message ▸ Sender:
the contact ▸ Run Immediately ▸ Next ▸ New Blank Automation ▸ add **Vibrate Wearable** (OpenCircuit),
Times as you like ▸ Done. The Message trigger covers Apple's Messages app only (unverified).

**Wake alarm every night.** Shortcuts ▸ Automation ▸ New Automation ▸ Sleep (or Focus ▸ Sleep ▸ When
Turning On) ▸ Run Immediately ▸ Next ▸ New Blank Automation ▸ add **Set Wake Alarm on Wearable**, Time:
your wake time, Repeat: Once ▸ Done.

## How it works

- **Reaching the strap** (`Wearable/WearableShortcuts.swift`). Nothing is created or connected unless
  the strap is chosen AND saved (decision 1). A ready session is used at once, including one a
  background sync holds (#233): the buzz and the alarm write use the chunked link, the history fetch
  uses `…0004`/`…0005`, and `HelioSession` lets them run together (measured by
  `testABuzzAndAnAlarmWriteInsideTheFirstRoundLeaveTheSyncWhole`, which sends the buzz's start, the
  alarm's add and the buzz's stop inside the first fetch round, before its ack). Otherwise the action
  arms the existing standing connect (`HelioConnection.reconnectForShortcut` → `reconnectKnown`) and
  waits for the session for at most 15 s. Inside the 500 ms a busy disconnect waits before cancelling
  the link, it re-arms on that disconnect instead (`rearmAfterTeardown`), so the deferred cancel can't
  cancel its connect. Nothing is disconnected afterwards, so the link is left as a background run
  leaves it (B.5). A strap that ended "busy" is not reconnected (decision 7). Only before the first unlock
  after a restart, every action answers "Unlock your iPhone once after restarting, then try again."
  and reads or saves nothing (the stored choice and key aren't readable then). A phone that is merely
  locked (after its first unlock) runs the actions normally: that is when a Message or bedtime
  automation runs. The check reads a Keychain sentinel created at launch with the strap key's own
  class, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`Wearable/FirstUnlockGate.swift`): only
  `errSecInteractionNotAllowed` refuses; a missing sentinel or any other error proceeds (and is logged).
  `UIApplication.isProtectedDataAvailable` is not used: it is false whenever a passcode phone is locked. If iOS cancels a
  Vibrate run, no further buzz starts and the result says how many ran.
- **The managed slot** (`Helio/StrapWakeAlarm.swift`). A pure planner decides from the strap's list, the
  managed record and the request: a once-request whose time has passed → dropped, nothing sent
  (decision 52e); the managed slot already holding the alarm → no write; another slot holding it →
  nothing added, and the managed slot deleted if it still matches its record, so only the person's alarm
  fires (decision 52f; a managed slot that no longer matches is left alone); the managed slot still as
  written → replace it; changed or gone → forget it and add a new one (no free slot → refuse); a
  once-alarm that fired (disabled, at the record's slot and time, whatever repeat byte the strap wrote
  into it; what the strap does to a fired once-alarm is 🔴, §13.5) → re-enable it in place; no other slot is ever named; a record for another strap counts as none, and a request
  made for another strap (or none) is dropped. The request (with the strap it was made for) is
  saved in UserDefaults (`helio.shortcutWakeAlarm.v2`; a `v1` record keeps its managed slot and drops its
  request, which names no strap) BEFORE anything is sent, applied now if the
  strap is ready, otherwise right after the next connection's setup alarm read (the clock is set before
  it). The record changes only when the strap's re-read confirms the slot and every other slot unchanged.
  Nothing is retried on the same connection. A set the strap refused or never acknowledged stays pending
  for the next connection. A set the strap ACKNOWLEDGED but whose re-read didn't confirm it is finished
  ("couldn't confirm", logged) and never added again at a later connection, so whatever the strap reads
  back, at most one extra slot is ever used (review-261b U-A). Every set is also saved as a candidate
  before it goes out; if it is never confirmed (a lost ack, a drop before the re-read, another central's
  change), the next list read adopts it as the managed slot if that slot holds exactly what was written,
  and drops it otherwise. A set the strap refused with a status (it applied nothing) drops its candidate
  at once; one with no ack keeps it. Any alarm write OpenCircuit
  didn't make to the managed slot (or the candidate's), such as the person's own edit or delete on the
  Alarms screen, makes that slot the person's: the record is forgotten. A Clear while a Set's write is
  still out queues behind it and removes it once written. Writes made for Shortcuts leave the Alarms
  screen's status line alone. The Alarms screen marks the slot "Set by Shortcuts".
- **Logs**: `helio` log lines prefixed `shortcuts:`; the outcome is public, any time of day private.

## The ring (RingConn Gen 3, decision 52g)

**Untested on hardware**: no Gen 3 was available while this was built; everything below runs against
fakes in `RingShortcutTests`.

- **Gen 3 only.** Vibrate decides from the connected session (`supportsVibration`); Set and Clear decide
  from the cached model (`RingMetadataStore`) and need no connection. A Gen 2 or Gen 2 Air is refused
  ("doesn't have a motor OpenCircuit can drive"); an unknown model asks to open the app with the ring
  connected once.
- **Vibrate** runs only with the ring chosen AND a saved ring: `RingScanner.reconnectKnownPeripheral()`
  (no central without a saved ring, #142), then up to 15 s for a session that is ready, knows its model
  and is idle (no drain, live read, workout or calibration). A cold launch's central isn't powered on
  yet, so the call returns false with the connect armed for power-on: with an active ring the action
  waits the 15 s rather than give up. A ring that comes up but never names its model says so. `RingSession.vibrate` keeps its own guards;
  a "busy" refusal is waited out inside the same 15 s, never forced. Buzzes are 2 s apart.
- **A ring that has just (re)connected often drains first** (read from the code, not a capture): with the
  app in the background (as it is when a Shortcut runs), the first descriptor frame (`0x10`/`0x87`, the
  answer to the keepalive's first `07` fetch, sent ~0.25 s after it starts) goes through
  `maybeDrainOnBackgroundWake` → `evaluatePeriodicDrain`, which starts a history drain whenever the last
  drain is older than 1 h by day (3 h in battery saver), outside the sleep window. With the app in front, `ContentView`'s
  activation sync can also start one. Overnight (the sleep window) no automatic drain runs, so a
  night-time buzz is not held up this way. A drain's length on a Gen 3 isn't measured here; a drain longer
  than the 15 s window makes Vibrate answer "stayed busy syncing; try again in a minute" without buzzing.
- **Set Wake Alarm** replaces OpenCircuit's one ring alarm (`RingAlarmController`): time, days and on,
  keeping the person's pattern, burst and backup-alert settings. Repeat maps onto its weekdays (Every Day
  = all, Weekdays = Mon–Fri, Weekends = Sat and Sun). **Once** is a one-shot: it fires only for the first
  occurrence after the moment it was set (set inside its own minute, that is the next day's, exactly as
  the strap's request), inside the same 15-minute grace, then turns itself off
  (its backup notification is a single non-repeating one at that occurrence). It never fires for a later
  occurrence. A one-shot stays one while only the pattern or backup alert is edited on the alarm screen;
  a time, day or on/off edit makes it the person's ordinary alarm.
- **Clear** turns the ring alarm off only while it still holds what Shortcuts last set
  (`shortcuts.ringAlarm.v1`); an alarm changed in the app since is left alone.
- The ring alarm screen shows one line: "Once" for a one-shot, "Set by Shortcuts" while it still matches.
- **The honest limits** (`docs/RELEASE_NOTES_b51.md`): the ring has no alarm of its own (🔴 none known), so
  OpenCircuit buzzes it at the first moment it hears from the ring at or after the time. That can be up to
  15 minutes late, and is skipped if the ring is charging, disconnected, or the app was swiped closed. The
  backup notification is the guaranteed part; the Set dialog says whether it is on.

## Limits

- A background run can't reach a strap out of range. Vibrate Wearable then says it couldn't reach the
  strap, and no buzz is kept for later. Set Wake Alarm keeps its request and applies it at the next
  connection. A Once request whose time has passed by then is dropped and nothing is written (decision
  52e: the next occurrence of its hour:minute after the moment it was asked is checked at apply time);
  repeating requests never expire.
- The strap fires its alarm on its own clock, which OpenCircuit sets to the phone's local time on every
  connection (decision 9). A time-zone or DST change takes effect at the next connection.
- If the link drops mid-buzz, the strap may keep buzzing until the next connection sends the owed stop
  (decision 18, persisted across processes).
- How long iOS lets an action run in the background is not documented; the strap path can take up to
  about 15 s (reach) + 12 s (alarm write and re-read).
- The managed slot (and an unconfirmed set's candidate) is known by its slot and content. Any alarm
  identical to OpenCircuit's that someone makes in that slot from the Zepp app or another phone can't be
  told apart from OpenCircuit's own, whether OpenCircuit is connected or not: a delete and an identical
  re-add of the managed alarm, or an identical alarm made while OpenCircuit's write is unconfirmed (no
  ack). Either would still be treated as OpenCircuit's. The same done on OpenCircuit's Alarms screen is
  seen, and makes the slot the person's.
- The re-arm inside a disconnect's 500 ms window relies on CoreBluetooth reporting the cancelled link's
  disconnect; that path has no unit test (no `CBPeripheral` in tests) and is unverified on a phone.
