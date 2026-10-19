# Reference material

Provenance for everything this project learned from, and how each thing was obtained. Nothing in
this directory is a binary, a screenshot or an extracted asset — it is the record of what was
read, when, and from which version.

The recordings themselves live in `../captures/`, one directory per session, each with its own
`capture.json` naming the model, the firmware string, the tool, the date and the channel.

---

## The reference app

Everything on this page that is not a measurement of the hardware is a reading of the vendor's
own phone app, used to answer questions the captures could only hint at. It is read, never
copied: no code, no assets, no fonts, no icons, and no JSON from inside it appear anywhere in
this repository or in any release.

| | |
|---|---|
| Package | `com.heytap.headset` |
| `versionName` | `116.9.0` |
| APK SHA-256 | `89368eb2b33abbec1c783b70439679eb0f0a9fea56706999122ab8a3d0ca13b5` |
| How it was read | JADX decompilation to a scratch directory outside this repository |
| What was extracted from it | **Nothing.** Only names, ids and behaviour were read, and each is recorded in `../protocol/` with a citation to the class and method it came from |

The APK is model- and region-dependent. A different `versionName` may carry a different command
table, so every finding that came from it names this tuple. Findings that came from a capture
name the capture instead, and a capture always wins an argument with the APK.

## Capture tooling

Three tools appear in the provenance records:

- **`BUDSBAR_TRACE=1`** on the single-device app: dumps every raw `RX`/`TX` frame. `BUDSBAR_HARVEST=1`
  additionally sweeps each mode, level, EQ preset and BassWave setting — using only the
  allow-listed setters — so a capture contains one clean example of every frame type, and restores
  what it found. This is how `captures/oneplus-buds-4-2026-10-17` was taken.
- **`BUDSDESK_TRACE=1`** on this app, which exists so the loop does not depend on that one:
  `BUDSDESK_TRACE=1 BUDSDESK_TRACE_FILE=/tmp/buds.log ./BudsDesk.app/Contents/MacOS/BudsDesk`
  appends every frame in both directions to `/tmp/buds.log`. It is written from the RFCOMM
  callback, before reassembly, because a capture wants what the radio delivered rather than what
  the codec made of it — a fragment is evidence. TX lines are written only when the write was
  accepted, so the log records the wire and not the attempt.
- **`Tools/trace-to-capture.py`** turns that log into a capture directory. It copies the bytes out
  verbatim, stamps each with its arrival time, refuses to overwrite an existing capture, and stops
  on any line that does not parse as a frame whose two length fields agree. What it does **not** do
  is name the frames or supply the firmware string: naming a frame is an interpretation, and a
  firmware string is a fact about a device that the tool cannot observe. Inventing either would
  make every claim below the capture inherit the invention.
- **`Tools/hardware-loop.md`** (BudsDesk's own): the scripted per-model pass that writes each
  allow-listed setter, reads it back, and records pass/fail against the firmware string.

The division is deliberate: the machine copies bytes and the person names them. A capture produced
any other way is a capture somebody typed.

## Reading HCI from a phone

Not yet used, but recorded because it is the richest source for a model we do not own: enable
Developer Options → *Enable Bluetooth HCI snoop log*, toggle Bluetooth, exercise every screen in
the reference app, then pull `btsnoop_hci.log` and open it in Wireshark filtered to `rfcomm`.
When such a log is added it becomes a capture directory like any other, with
`direction: both` and a note saying whose phone it came from.

## The channel

One vendor serial service carries all of this:

| | |
|---|---|
| Service name | `oppointeraction` |
| Service UUID | `0000799a-d102-11e1-9b23-00025b00a5a5` |
| RFCOMM channel | resolved from SDP at runtime (15 on the measured unit) |
| Other channels seen on some models | 12 (`Realme Pearl`), 17 (`RFCOMM COM`) |
| **Never opened** | **13 (`BESOTA`) — the firmware OTA channel. Out of scope permanently; see `../SCOPE.md` §4** |

Only one process may hold the channel. A stale holder makes the next open fail *silently*, which
is why a "discovery returned nothing" symptom is usually a permission or exclusivity problem
rather than a protocol one.
