# Shortcuts actions for the wearable (#260, decision 52)

iOS lets no app see other apps' notifications or the Clock app's alarms (`ZEPP_PROTOCOL.md` §13.3),
so OpenCircuit can't relay them itself. Shortcuts personal automations are the bridge: an automation
reacts to the event, and runs one of OpenCircuit's actions.

| Action | What it does | Devices |
|---|---|---|
| **Vibrate Wearable** (Times 1–5, default 1) | Buzzes the wearable in use that many times, with a short gap. The strap's buzz is a find-device start and its stop (§13.2; decision 19, 2 s). The action returns only after the stop (`06`) was sent, plus 0.5 s for it to leave the radio. | Strap; a RingConn Gen 3 ring whose link is already up (no ring reconnect). |
| **Set Wake Alarm on Wearable** (Time, Repeat: once by default) | Stores ONE alarm on the strap itself, which then fires it on its own (§12: 60 s of vibration, tap to stop), with no phone needed at wake time. Only the time's hour and minute are used. | Strap only. The ring stores no alarms: the action says so and points to the ring's own wake-up alarm (Profile ▸ Device Info ▸ Vibration & alarm). |
| **Clear Wake Alarm on Wearable** | Deletes that one alarm, only while it is still as OpenCircuit wrote it. | Strap only. |

The actions run in the background (`openAppWhenRun = false`) and on a locked phone
(`authenticationPolicy = .alwaysAllowed`): they disclose no health data. Every name and dialog comes
from the active device's descriptor (`ActiveDeviceChoice.onDemandVibration`, `.wakeAlarm`, decision 51e).

## Example automations (not yet verified on a phone)

**Buzz for messages from one person.** Shortcuts ▸ Automation ▸ New Automation ▸ Message ▸ Sender:
the contact ▸ Run Immediately ▸ Next ▸ New Blank Automation ▸ add **Vibrate Wearable** (OpenCircuit),
Times as you like ▸ Done. The Message trigger covers Apple's Messages app only.

**Wake alarm every night.** Shortcuts ▸ Automation ▸ New Automation ▸ Sleep (or Focus ▸ Sleep ▸ When
Turning On) ▸ Run Immediately ▸ Next ▸ New Blank Automation ▸ add **Set Wake Alarm on Wearable**, Time:
your wake time, Repeat: Once ▸ Done.

## How it works

- **Reaching the strap** (`Wearable/WearableShortcuts.swift`). Nothing is created or connected unless
  the strap is chosen AND saved (decision 1). A ready session is used at once, including one a
  background sync holds (#233): the buzz and the alarm write use the chunked link, the history fetch
  uses `…0004`/`…0005`, and `HelioSession` lets them run together (measured by
  `testABuzzAndAnAlarmWriteDuringASyncLeaveTheSyncWhole`). Otherwise the action arms the existing
  standing connect (`HelioConnection.reconnectKnown`) and waits for the session for at most 20 s. Nothing
  is disconnected afterwards, so the link is left as a background run leaves it (B.5). A strap that ended
  "busy" is not reconnected (decision 7).
- **The managed slot** (`Helio/StrapWakeAlarm.swift`). A pure planner decides from the strap's list, the
  managed record and the request: the same alarm already on the strap → no write; the managed slot still
  as written → replace it; changed or gone → forget it and add a new one (no free slot → refuse); a
  once-alarm that only lost its enabled bit (the strap may disable it after it fires, §13.5 🔴) →
  re-enable it; no other slot is ever named; a record for another strap counts as none. The request is
  saved in UserDefaults (`helio.shortcutWakeAlarm.v1`) BEFORE anything is sent, applied now if the
  strap is ready, otherwise right after the next connection's setup alarm read (the clock is set before
  it). The record changes only when the strap's re-read confirms the slot and every other slot unchanged;
  any other outcome keeps the request for the next connection, and nothing is retried on the same one.
  The Alarms screen marks the slot "Set by Shortcuts".
- **Logs**: `helio` log lines prefixed `shortcuts:`; the outcome is public, any time of day private.

## Limits

- A background run can't reach a strap out of range. Vibrate Wearable then says it couldn't reach the
  strap, and no buzz is kept for later. Set Wake Alarm keeps its request and applies it at the next
  connection, which may come after the time has passed (a once-alarm then fires at that time the next day).
- The strap fires its alarm on its own clock, which OpenCircuit sets to the phone's local time on every
  connection (decision 9). A time-zone or DST change takes effect at the next connection.
- If the link drops mid-buzz, the strap may keep buzzing until the next connection sends the owed stop
  (decision 18, persisted across processes).
- How long iOS lets an action run in the background is not documented; the strap path can take up to
  about 20 s (reach) + 12 s (alarm write and re-read).
