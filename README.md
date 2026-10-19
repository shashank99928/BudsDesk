# BudsDesk

A native macOS app that drives **OPPO / OnePlus / realme TWS earbuds** over the vendor's own
Bluetooth control channel — built by measuring the hardware, not by guessing at it.

The earbuds ship with a phone app and there is no desktop equivalent. On a Mac they are a Bluetooth
audio device and nothing more: no noise control, no equalizer, no gesture remapping, and one merged
battery figure at best. BudsDesk is that missing desktop app, built the slow way — every byte it
sends was first seen in a recording of real hardware, and every claim it makes is labelled as
measured, inferred, or unconfirmed.

**[Download for macOS](https://github.com/shashank99928/BudsDesk/releases/latest/download/BudsDesk.dmg)** ·
[Website](https://shashank99928.github.io/BudsDesk/) ·
[Protocol notes](protocol/PROTOCOL.md)

> **Status: v0.1.0, one model verified.** OnePlus Buds 4 is measured end to end and every control
> listed as "measured" below writes to it. Any other model in the family connects and reads, with no
> write path, because nothing about writing to it has been observed. That is a design decision, not a
> gap waiting to be filled by optimism.

---

## What it does

On the measured model, the OnePlus Buds 4:

| | OnePlus Buds 4 (measured) | Other family models |
|---|---|---|
| Connect / read state | measured | reads; unconfirmed |
| Battery, left and right | measured, reported separately | reads; unconfirmed |
| Battery, charging case | **never reported on this channel** — see below | unknown |
| Wear / in-ear state | measured | reads; unconfirmed |
| Noise control — modes and levels | measured, writes | no write path |
| Equalizer presets | measured, writes | no write path |
| Custom EQ slot | read (presence only) | unknown |
| BassWave | measured, writes, range −5…+5 read from the device | no write path |
| Touch gesture remapping | measured, writes, limited to observed actions | no write path |
| Multi-connect list | measured, read-only | no write path |
| Multi-connect switch | unconfirmed | unconfirmed |
| Firmware string | measured, read-only, shown verbatim | reads; unconfirmed |
| Codec | measured, read-only | reads; unconfirmed |
| Prompt volume | **not implemented** — no code path exists | none |
| Firmware update | **out of scope, permanently** | out of scope |

**"Battery, charging case" is a missing report, not a missing feature.** Across a whole capture
session every battery reply carried exactly two slots — left and right — even while the wear reply
named the case on every poll. The case's charge reaches the phone app by some path this channel does
not show. BudsDesk says *"the case has not reported a charge"* rather than drawing an empty battery.

**"Prompt volume" is deliberately in this table as not implemented.** The getter's id was observed on
hardware in an earlier experiment, but no request, decoder or control exists in this repository, so
the table says so. A row that read "measured" here would describe an experiment rather than the app.

## What this app will never do

- **Never touch the firmware OTA channel.** Updates live on a separate service (BESOTA, RFCOMM
  channel 13). BudsDesk does not open it — not for discovery, not for testing, not out of curiosity.
  See `SCOPE.md` §4.
- **Never send a command id that has not been seen in a capture.** No fuzzing, no enumerating ids, no
  "probably this one".
- **Never write a setting the hardware has not been observed to accept.** An unconfirmed capability
  has no write path, by construction.
- **Never talk to a network.** No accounts, no telemetry, no analytics, no update checks. It speaks
  to the earbuds and nothing else, and can be run with the network down.
- **Never ship a vendor's asset.** No decompiled code, no extracted icons or fonts, no data lifted
  out of the phone app. Every visual here is drawn by code in this repository.

## How it is built

Evidence first, prose second. The layering is one-way and the protocol core has no radio in it:

```
UI (SwiftUI/AppKit)  →  Session (state machine, polling, write + read-back)
                          →  Codec (framing, payload schemas, total parsers)
                             →  Transport (IOBluetooth RFCOMM today; WinRT / BlueZ later)
                                →  CapabilityRegistry (devices/*.json)
```

- **The codec is pure and total.** Every parser returns a value or rejects: no raw subscripts, no
  trapping arithmetic, no force unwraps on frame data. A malformed frame cannot crash the app, and
  tests feed it truncated, over-long and hostile-length frames to prove it.
- **Writes are never optimistic.** `Session` reads back every write, and only a reply changes what
  is displayed. A declined write looks like the control snapping back, which is the correct
  behaviour and the only honest one.
- **The registry is enforced, not documentation.** A capability has `read`, `writable` and a
  `confidence`, and the confidence must cite its evidence. `writable: true` on anything that is not
  `measured` fails to load; so does `inferred` without a vendor-app reference, or `unconfirmed` with
  one. The rules were verified by breaking the shipped profile and confirming the named error.
- **The captures are the fixtures.** `captures/<id>/frames.hex` is a recording with provenance in
  `capture.json`. The Swift corpus is generated from it and a test asserts the two agree byte for
  byte, so a fixture whose length field disagrees with its payload cannot exist. Nothing is
  transcribed by hand.
- **A model nobody catalogued still works.** It matches the fallback profile, connects, reads
  everything the earbuds report, and draws no control it cannot back up.

## Command line

The same binary does both jobs. Every mode below is inert with respect to hardware except when it
has to connect, and `--replay` never opens a radio at all.

```sh
BudsDesk                        # the app
BudsDesk --selfcheck            # 182 protocol checks against the corpus
BudsDesk --profiles             # the capability registry, with every gate on it
BudsDesk --devices              # paired devices advertising the control service
BudsDesk --replay <capture>     # a recorded session, read back through the real Session
BudsDesk --version
```

`--replay` is the interesting one: it drives the real session with a recording instead of a radio,
which is how the app is tested without fighting the running app for the one control channel there is.

## Repository layout

| Path | What it is |
|---|---|
| `SCOPE.md` | What is in scope and, more importantly, what is permanently out |
| `DECISIONS.md` | Each architectural choice: options, evidence, choice, what would change it |
| `protocol/` | The protocol as prose (`PROTOCOL.md`) and as data (`spec.yaml`), including what is *not* verified |
| `capture/` | Provenance for the reference recording and the APK that was read |
| `captures/` | The recordings themselves — the source of truth |
| `devices/` | The capability registry: one file per model, and the rules a profile must pass |
| `Sources/BudsCore/` | The portable protocol core — Foundation and `os` only, no radio |
| `Sources/BudsDeskMac/` | Transport, discovery, session hosting and UI for macOS |
| `Tests/` | Corpus replay, total-parser, registry and session tests |
| `Tools/` | Capture freezing and harvesting, the SF Symbol check, icon and disk-image art |

## Building

```sh
swift test        # corpus replay + total parsers + registry + session
./build.sh        # assembles BudsDesk.app, checks symbols, runs the self-check
./make-dmg.sh     # build.sh, plus a styled drag-to-install disk image
```

`build.sh` runs the SF Symbol check first — the cheapest thing that can fail, and the failure it
catches is invisible, since SwiftUI draws nothing for a symbol name the OS does not know and reports
no error. It then assembles the bundle, copies the capability registry inside it, and runs
`--selfcheck` **and** `--profiles` against the release binary. A registry that is valid on disk and
missing inside the app fails the build.

Requires macOS 26+, Apple silicon, and `swift-tools-version: 6.2`. An installed Xcode is needed only
for its SwiftUI macro plugin; it need not be selected with `xcode-select`.

The release build is ad-hoc signed. Set `SIGN_IDENTITY` for a Developer ID signature, and
`NOTARY_PROFILE` to notarise and staple the disk image.

## Related work

Different vendors, same missing piece, and all of it unpaid:

- [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller) — macOS client
  for realme earbuds, MIT, and it documented the same absence independently.
- [GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient) and
  [nothing-x-macos](https://github.com/nikiomori/nothing-x-macos) — Samsung and Nothing.
- [FreeBuddy](https://github.com/TheLastGimbus/FreeBuddy) — Huawei FreeBuds.

None of them shares code with BudsDesk.

## Licence

MIT — see `LICENSE`. BudsDesk is not made by, endorsed by, or affiliated with OPPO, OnePlus, realme,
BBK Electronics, or the publisher of the phone companion app. Product names appear only as factual
device names.
