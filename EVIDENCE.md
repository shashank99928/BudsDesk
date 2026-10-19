# Evidence

Every protocol fact this project states, where it came from, and how to re-check it. A fact without
a row here does not belong in the app, the docs or the site.

Two rules hold the table together:

1. **Confidence is one of three words, and they are never blurred.** `measured` — taken off a wire
   or read out of a shipped artefact, and cited to the byte. `inferred` — the only explanation that
   fits the measurements, stated as such. `unconfirmed` — a plausible reading with no witness.
2. **A citation is a location, not a memory.** Every row names a file, and where it can, an offset,
   a class, a method, or a frame. Re-running the command in *How to reproduce* has to land on it.

This ledger was opened 2026-10-19. Its first job was to settle the control service UUID, and it did
that by contradicting the repository.

## How to reproduce

```bash
# The APK's raw string table, with the file offset of every string (no decompiler in the path).
python3 Tools/dex-strings.py "$APK" --uuid
python3 Tools/dex-strings.py "$APK" --grep 'd102-11e1-9b23-00025b00a5a5'

# The device's own SDP record, read-only: no RFCOMM channel is opened.
swift Tools/probe-sdp.swift            # or any IOBluetooth enumerator; see capture/sdp-*.txt
```

`Tools/dex-strings.py` reads the documented DEX container directly rather than decompiling it,
because a decompiler is lossy: `jadx` rewrites bytecode into Java and drops what it cannot attribute
to a class, and the held UUID is one of the things it drops.

## Inputs

| Input | sha256 | Notes |
|---|---|---|
| `com.heytap.headset_116.9.0.apk` | `89368eb2b33abbec1c783b70439679eb0f0a9fea56706999122ab8a3d0ca13b5` | HeyMelody 116.9.0. **Evidence only** — no code, string, art or animation from it enters this repository, the app or the site. |
| `classes.dex` | `05d8e8163f3fde7d8afd1a4ecfca7a4eb5c7538ef5cd2b1c257985d605867790` | 9,525,992 bytes, 60,878 strings. |
| `classes2.dex` | `dc4fb63d0a95dfff861b366e902f946b3e79b2b85d9fd2455b7aa80fcd27e377` | 263,888 bytes, 1,968 strings. |
| `classes3.dex` | `6cc9eca2d869c6fd449f75c09fc984f3d85256a135fc4de7077f0bc045d91439` | 3,747,368 bytes, 26,125 strings. |
| `capture/sdp-oneplus-buds-4-2026-10-19.txt` | `fcc984fd9da3b4fec25acd038b5732bd38ed096d67bd662c57f7005e5c799bc7` | The earbuds' own SDP record. Read-only. |
| `captures/oneplus-buds-4-2026-10-17/` | — | 25 frames, one recording, on the wire. See its `capture.json`. |

Tools used: `jadx` 1.5.6, `apktool` 3.0.3, Swift 6.2, Python 3.14.6, macOS 26.5 on Apple silicon.

## Facts

| # | Fact | Confidence | Citation |
|---|---|---|---|
| 1 | The control service UUID is `0000079a-d102-11e1-9b23-00025b00a5a5`. | **measured** | Device SDP, record named `enco link`, attribute `0x0001`: `uuid128(00 00 07 9a d1 02 11 e1 9b 23 00 02 5b 00 a5 a5)` — `capture/sdp-oneplus-buds-4-2026-10-19.txt`. Corroborated by `classes.dex:0x6a6bbe` and by the app that produced the capture, `ear-macapp/Sources/BudsBarKit/Buds.swift:52`. |
| 2 | The control service is named `enco link` on the wire. | **measured** | Same record, attribute `0x0100` (decimal 256): `string(enco link)`. |
| 3 | The control service's RFCOMM channel is 15. | **measured** | Same record, `0x0004` protocol descriptor list: `{ uuid32(00 00 00 03), uint32(15) }`. Agrees with `captures/oneplus-buds-4-2026-10-17/capture.json`. |
| 4 | The same device also advertises `RFCOMM COM` on channel 17 and `WATCH` on channel 29. | **measured** | Same capture. Channel 17 was already known; **channel 29's purpose is unknown and is not documented anywhere in this project.** |
| 5 | Channel 13 (`BESOTA`) is not advertised. | **measured** (for this record) | Same capture: zero services on channel 13. An SDP record is not a promise about firmware, so this changes nothing about the standing rule: channel 13 is never opened. |
| 6 | The vendor's UUID space is a family, not one UUID: `0000079a`, `0100079a`, `0200079a`, `0000079c`, `0100079c`, `00001107`, all on the base `-d102-11e1-9b23-00025b00a5a5`. | **measured** | `classes.dex:0x6a6bbe`, `0x6a6c0a`, `0x6a7002`, `0x6a7072`; `classes3.dex:0x2a0231`, `0x2a0257`, `0x2a027d`, `0x2a030c`. |
| 7 | The leading `00`/`01`/`02` in those UUIDs selects a product family or variant. | **inferred** | The pattern is consistent across two service numbers, but no witness in the APK or on the device states what the prefixes mean. Do not build a registry rule on this yet. |
| 8 | The mapping from a UUID to a *brand* is not in the app: no `oppo`/`oneplus`/`realme` literal is used to choose a service. | **inferred** | The service names are absent from the pools entirely (see #10), and the only brand literals present are in a log redactor (see #9). |
| 9 | The app redacts brand names, the middle of MAC addresses, the middle of IPv4 addresses and the middle of UUIDs before writing them anywhere. | **measured** | `classes.dex:0x69b198`, a single regex: `((?<![a-z.])(oppo\|oneplus\|realme)(?![a-z])\|一加\|真我)\|((?<=[0-9a-f]{8}-[0-9a-f]{4}-)[0-9a-f]{4}(?=-[0-9a-f]{4}-[0-9a-f]{12}))\|…`. This is privacy behaviour, **not** a device classifier. |
| 10 | The app does not hardcode the service *name*; it reads it from SDP. | **inferred** | Neither `oppointeraction` nor `enco link` occurs anywhere in the 88,971 strings of the three DEX images. A name that is not in the app is a name the app gets from the device — which is also why a name is a poor identifier and a UUID is a good one. |
| 11 | No vendor native library ships. The only `.so` files are Glide's WebP codec. | **measured** | `lib/arm64-v8a/libglide-webp.so`, `lib/armeabi-v7a/libglide-webp.so`, and nothing else under `lib/`. The protocol is Java/Kotlin. |
| 12 | There is no structured product table in `resources.arsc`. | **measured** | 4,748,516 bytes; model names appear only inside localised tutorial prose (`Enco Buds`, `Enco Free2`), not as a device table. |

## Worked example: the control service UUID

The repository recorded `0000799a-d102-11e1-9b23-00025b00a5a5` in 13 places — the registry JSON that
gates matching, the protocol spec, the capture's own metadata, the docs, and two pages of the public
site. **It is wrong.** The correct value is `0000079a-…`, one digit different.

Three witnesses, none of which is this repository:

1. **The earbuds.** Their SDP record advertises `00 00 07 9a …` (fact #1). This is the arbiter.
2. **The APK.** The value is in the raw string pool at `classes.dex:0x6a6bbe`, a file with a hash,
   findable by anyone with the same APK.
3. **The app that captured the frames.** `ear-macapp/Sources/BudsBarKit/Buds.swift:52` has always
   used bytes `0x00, 0x00, 0x07, 0x9a, …`.

Why it survived: the constant exists twice in `Sources/BudsDeskMac/DeviceCatalog.swift` — as a byte
array (correct) and as a display string (wrong). The byte array is what opens the channel, so the
app worked; the string is what got published. And the registry's UUID gate compares the string
against *our own JSON*, which held the same wrong value, so the gate agreed with itself forever.
A self-consistent pair of errors is invisible to every test that only checks consistency.

What changes because of this: the published fact (docs, site, spec, registry data) and the app's own
trace line. What does **not** change: runtime behaviour, which was never reading the string. The
regression test added alongside this entry compares the two representations in `DeviceCatalog.swift`
and every registry profile against the capture's recorded UUID, so the pair cannot drift again.

## Negative results

Written down because a negative result is a result, and because each one closes a line of enquiry.

- **No vendor native code**, so there is no `.so` to decompile for the protocol state machine (#11).
- **No device table** in resources — the model names that exist are UI prose (#12).
- **No service names** in the app at all (#10).
- **No structured gesture data** in `assets/coui_*_gesture_guidance*.json`: those are Lottie
  animations (format version 5.9.6, `layers`/`ks`), i.e. copyrighted art, not behaviour. They are
  evidence of nothing about the protocol and must never be shipped.
- **No Android device is attached** (`adb devices` is empty), so no Frida hook and no HCI snoop log.
  The phone app's own byte stream — the single most valuable artefact available for this work — has
  not been captured.
- **The harness's Android decompiler is unavailable** (`REA_JADX_MCP_JAR` is unset and is not
  fetched). The locally installed `jadx` 1.5.6 and `apktool` 3.0.3 were used instead, plus
  `Tools/dex-strings.py`, which does not decompile at all.

## Corrections to earlier claims

- Earlier notes said the APK "contains no literal `oppointeraction`, `BESOTA`, `Realme` or `Pearl`
  strings", implying nothing protocol-relevant was in it. That was measured against the *decompiled*
  tree. Against the raw string pool it is false: the UUID family is there (#6), as is the brand
  redactor (#9). The claim was about the instrument, not the artefact.
- Earlier notes called the brand regex a device classifier. It is a **log redactor** (#9).
- The service *name* `oppointeraction` has **no witness in any input** (facts #2, #10). The device
  says `enco link`.

## Open questions

- What do `0100079a`, `0200079a`, `0000079c` and `0100079c` select? (#7)
- What is channel 29, `WATCH`, for? (#4) It is advertised by hardware this project supports, and
  nothing in the repository mentions it.
- Where does the device table come from, if not the APK? If it is fetched at runtime, the phone
  app's own traffic is the only way to see it, which needs an attached device.
- Does any other model in the family advertise the control service under a *different* UUID from
  the namespace in #6? One device has been read. The registry's gate should be able to answer this,
  and currently cannot, because it compares the registry to itself.
