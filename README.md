# BudsDesk

A native macOS app for **OPPO / OnePlus / realme TWS earbuds** — built by measuring the hardware's
own vendor control channel, not by guessing.

BudsDesk is *device-generic*. One binary drives any model in the family that advertises the
vendor's `oppointeraction` control service. What each model can do lives in a capability registry
(`devices/*.json`), not in `if model == …` branches, so a model nobody has catalogued yet still
connects, still shows what it can read, and never pretends to control something it hasn't been
shown to control.

> **Status: pre-release.** The protocol core is ported and verified against 25 hardware captures.
> The app itself is being built in phases. Nothing here should be treated as a finished product
> yet — see the support matrix below for exactly what is measured and what is not.

---

## Why it exists

The earbuds ship with a phone app. There is no desktop equivalent: on a Mac, the same earbuds are
a Bluetooth audio device and nothing more. Their noise control, equalizer, gesture mapping and
multi-connect state are reachable only from a phone.

BudsDesk is that missing desktop app, built the slow way: every byte it sends was first seen in a
recording of the hardware, and every claim it makes is labelled as measured, inferred, or
unverified.

## Support matrix

Honest, and kept current. `unconfirmed` means no write path exists in the app for that feature on
that model — by construction, not by caution.

| | OnePlus Buds 4 (measured) | Other family models |
|---|---|---|
| Connect / read state | ✅ measured | expected; unconfirmed |
| Battery (buds) | ✅ measured | expected; unconfirmed |
| Battery (case) | ⚠️ never reported on this channel — see below | unknown |
| Wear / in-ear state | ✅ measured | expected; unconfirmed |
| Noise control (modes + levels) | ✅ measured | expected; unconfirmed |
| Equalizer presets | ✅ measured | expected; unconfirmed |
| Custom EQ slot | read-only (presence only) | unknown |
| BassWave | ✅ measured range −5…+5 | unknown range |
| Gestures (map an action) | ✅ measured, limited to observed actions | unknown |
| Multi-connect (read) | ✅ measured | unknown |
| Multi-connect (write) | unconfirmed | unconfirmed |
| Firmware string (read) | ✅ measured, shown verbatim | expected; unconfirmed |
| Codec (read) | ✅ measured | expected; unconfirmed |
| Prompt volume | getter measured; scale unmeasured → no control | none |
| Firmware update | **out of scope, permanently** | **out of scope** |

**"Battery (case)" is not a missing feature, it is a missing report.** Across a full capture
session every battery reply carried exactly two slots — left and right — even while the wear reply
named the case on every poll. The case's charge reaches the phone app by some path this channel
does not show. BudsDesk says *"the case hasn't reported a charge"* rather than drawing an empty
battery.

## What this app will never do

- **Never touch the firmware OTA channel.** Firmware updates live on a separate service (BESOTA,
  RFCOMM channel 13). BudsDesk does not open it — not for discovery, not for testing, not out of
  curiosity. See `SCOPE.md` §4.
- **Never send a command id that has not been seen in a capture.** No fuzzing, no enumerating ids,
  no "probably this one".
- **Never write a setting the hardware hasn't been observed to accept.** An unconfirmed capability
  has no write path.
- **Never talk to a network.** No accounts, no telemetry, no analytics, no update checks. The app
  speaks to the earbuds and nothing else.
- **Never ship a vendor's asset.** No decompiled code, no extracted icons or fonts, no JSON lifted
  out of the phone app. Every visual here is drawn by code in this repository.

## How it is built

Evidence first, prose second. The layering is one-way:

```
UI (SwiftUI/AppKit)  →  Session (state machine, polling, write + readback)
                          →  Codec (framing, payload schemas, total parsers)
                             →  Transport (IOBluetooth RFCOMM today; WinRT / BlueZ later)
                                →  CapabilityRegistry (devices/*.json)
```

- **`Codec` is pure and total.** Every parser returns a value or rejects; no raw subscripts, no
  trapping arithmetic, no force unwraps on frame data. A malformed frame can never crash the app —
  there is a test that feeds it truncated, over-long and hostile-length frames to prove it.
- **`Session` is the only code that touches the radio**, and it reads back every write. A setter
  is only "applied" once a getter agrees; until then the UI keeps showing the old value. A declined
  write looks like the control snapping back, and that is the correct behaviour.
- **The captures are the fixtures.** `captures/<capture-id>/frames.hex` is a recording with
  provenance in `capture.json` (model, firmware string, tool, date, channel). The Swift corpus is
  generated from it, and a test asserts the two agree byte for byte — so a fixture whose length
  field disagrees with its payload cannot exist. Nothing here is transcribed by hand.

## Repository layout

| Path | What it is |
|---|---|
| `SCOPE.md` | What is in scope and, more importantly, what is permanently out |
| `DECISIONS.md` | Each architectural choice: options, evidence, choice, what would change it |
| `capture/` | Provenance for the reference recordings and the APK that was read |
| `captures/` | The recordings themselves — the source of truth |
| `protocol/` | The protocol as data (`spec.yaml`) and as prose (`PROTOCOL.md`) |
| `devices/` | The capability registry: one file per model |
| `Sources/BudsCore/` | The portable protocol core (Foundation only, no radio) |
| `Sources/BudsDeskMac/` | Transport, session and UI for macOS |
| `Tests/` | Corpus replay, total-parser, registry and (later) golden-image tests |
| `Tools/` | Capture freezing, the hardware loop, and asset generation |

## Building

```sh
swift build          # build
swift test           # corpus replay + total parsers + registry checks
./build.sh           # build the .app bundle and run its self-check
```

Requires macOS 26+, Apple silicon, and `swift-tools-version: 6.2`.

## Licence

MIT — see `LICENSE`. BudsDesk is not made by, endorsed by, or affiliated with OPPO, OnePlus,
realme, or the publisher of the phone app. Product names appear only as factual device names.
