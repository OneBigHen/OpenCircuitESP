# Shortcuts actions for the wearable (#260, decision 52)

iOS lets no app see other apps' notifications or the Clock app's alarms (`ZEPP_PROTOCOL.md` §13.3),
so OpenCircuit can't relay them itself. Shortcuts personal automations are the bridge: an automation
reacts to the event, and runs one of OpenCircuit's actions.

| Action | What it does | Devices |
|---|---|---|
| **Vibrate Wearable** (Times 1–5, default 1) | Buzzes the wearable in use that many times, with a short gap. The strap's buzz is a find-device start and its stop (§13.2; decision 19, 2 s). The action returns only after the stop (`06`) was sent, plus 0.5 s for it to leave the radio. | Strap; a RingConn Gen 3 ring whose link is already up (no ring reconnect). |
| **Set Wake Alarm on Wearable** (Time, Repeat: once by default) | Stores ONE alarm on the strap itself, which then fires it on its own (§12: 60 s of vibration, tap to stop, 🟡 Amazfit's own documentation, not yet observed by us), with no phone needed at wake time. Only the time's hour and minute are used. | Strap only. The ring stores no alarms: the action says so and points to the ring's own wake-up alarm (Profile ▸ Device Info ▸ Vibration & alarm). |
| **Clear Wake Alarm on Wearable** | Deletes that one alarm, only while it is still as OpenCircuit wrote it. | Strap only. |

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
  leaves it (B.5). A strap that ended "busy" is not reconnected (decision 7). Before the first unlock
  after a restart, every action answers "Unlock your iPhone once after restarting, then try again."
  and reads or saves nothing (the stored choice and key aren't readable then). If iOS cancels a
  Vibrate run, no further buzz starts and the result says how many ran.
- **The managed slot** (`Helio/StrapWakeAlarm.swift`). A pure planner decides from the strap's list, the
  managed record and the request: a once-request whose time has passed → dropped, nothing sent
  (decision 52e); the managed slot already holding the alarm → no write; another slot holding it →
  nothing added, and the managed slot deleted if it still matches its record, so only the person's alarm
  fires (decision 52f; a managed slot that no longer matches is left alone); the managed slot still as
  written → replace it; changed or gone → forget it and add a new one (no free slot → refuse); a
  once-alarm that only lost its enabled bit (the strap may disable it after it fires, §13.5 🔴) →
  re-enable it; no other slot is ever named; a record for another strap counts as none, and a request
  made for another strap (or none) is dropped. The request (with the strap it was made for) is
  saved in UserDefaults (`helio.shortcutWakeAlarm.v2`; a `v1` record keeps its managed slot and drops its
  request, which names no strap) BEFORE anything is sent, applied now if the
  strap is ready, otherwise right after the next connection's setup alarm read (the clock is set before
  it). The record changes only when the strap's re-read confirms the slot and every other slot unchanged;
  any other outcome keeps the request for the next connection, and nothing is retried on the same one.
  Every set is also saved as a candidate before it goes out; if it is never confirmed (a lost ack, a
  drop before the re-read, another central's change), the next list read adopts it as the managed slot
  if that slot holds exactly what was written, and drops it otherwise. Any alarm write OpenCircuit
  didn't make to the managed slot (or the candidate's), such as the person's own edit or delete on the
  Alarms screen, makes that slot the person's: the record is forgotten. A Clear while a Set's write is
  still out queues behind it and removes it once written. Writes made for Shortcuts leave the Alarms
  screen's status line alone. The Alarms screen marks the slot "Set by Shortcuts".
- **Logs**: `helio` log lines prefixed `shortcuts:`; the outcome is public, any time of day private.

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
- The managed slot is known by its slot and content. A delete and an identical re-add made in the Zepp
  app (or by another phone) while OpenCircuit isn't connected can't be told apart from OpenCircuit's own
  alarm, so it would still be treated as managed. The same done on OpenCircuit's Alarms screen is seen,
  and makes the slot the person's.
- The re-arm inside a disconnect's 500 ms window relies on CoreBluetooth reporting the cancelled link's
  disconnect; that path has no unit test (no `CBPeripheral` in tests) and is unverified on a phone.
