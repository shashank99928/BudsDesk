# The `oppointeraction` control channel, as measured

This is the wire protocol BudsDesk speaks: the vendor RFCOMM service named
`oppointeraction` on OPPO / OnePlus / realme TWS earbuds. It is written for someone who wants to
implement it themselves or check this implementation against the hardware.

Every byte-level claim below is labelled with one of three words, and the label is the point:

- **measured** — a frame in `captures/oneplus-buds-4-2026-10-17/frames.hex` shows it, or a
  hardware loop-back confirmed it. The claim names the frame.
- **inferred** — read out of the vendor phone app's own constants and *not* confirmed against
  hardware. The claim names what it was read from.
- **unconfirmed** — plausible from the shape of the protocol; nothing was observed. Never
  presented as working.

A claim is never written one level above its evidence. Where something is known to exist but has
not been observed working, this document says so rather than rounding it up.

Where a value could not be established at all it is written as `null` with a `# not established`
comment in `spec.yaml`, or left out, rather than filled in plausibly.

---

## Where this came from

Byte-level knowledge comes from three places, in descending authority:

1. **Recordings of the hardware.** `captures/oneplus-buds-4-2026-10-17/frames.hex` is the
   recording of record: 25 received frames from one OnePlus Buds 4, taken with `BUDSBAR_TRACE=1`
   on the single-device app. Every `measured` claim below cites a named frame in it. A capture
   always wins an argument with anything else.
2. **The vendor phone app, read for names and ids only.** The APK is `com.heytap.headset`
   `versionName 116.9.0`, SHA-256 `89368eb2b33abbec1c783b70439679eb0f0a9fea56706999122ab8a3d0ca13b5`,
   decompiled with JADX to a scratch directory *outside* this repository. What was taken is command
   names and numbers, cited as `dex:Class#method`. **Nothing** — no code, no asset, no font, no
   icon, no JSON — is redistributed. See `../capture/README.md`.
3. **The code's own constants**, which are themselves the subject of verification.

The reference APK is model- and region-dependent, so a finding that came from it is only as good
as that tuple. Findings from a capture name the capture instead.

---

## The channel

| | |
|---|---|
| Service name | `oppointeraction` |
| Service UUID | `0000799a-d102-11e1-9b23-00025b00a5a5` |
| RFCOMM channel | resolved from SDP at runtime; **15** on the measured unit |
| Never opened | **13 (`BESOTA`)** — the firmware OTA channel, out of scope permanently |

Only one process may hold the channel. The service UUID is the *gate* — every member of the
family advertises it — not a model identifier.

*Evidence: measured — `captures/oneplus-buds-4-2026-10-17/capture.json` (`service` block records
name, UUID and channel 15).*

---

## The frame

Every frame, in both directions:

```
aa <len:varint> b2 b3 <cmd> <msgType> <seq> <payloadLen:u16le> <payload…>
```

| Off | Bytes | Field | Meaning |
|---|---|---|---|
| 0 | 1 | `start` | Always `0xaa`. The only synchronization marker. |
| 1 | 1–5 | `len` | Base-128 LEB128 varint (continuation bit high). Counts **every byte after itself**: the seven remaining header bytes plus the payload. |
| 2 | 1 | `b2` | `0x00` in every frame this code builds and in every frame in the corpus. **Purpose not established.** |
| 3 | 1 | `b3` | `0x00` likewise. **Purpose not established.** |
| 4 | 1 | `cmd` | The subject. Getter ids and setter ids are **different namespaces** (below). |
| 5 | 1 | `msgType` | Request / reply / set / push. |
| 6 | 1 | `seq` | Sequence byte. Replies echo the request's value; the decoder does not validate it. |
| 7–8 | 2 | `payloadLen` | 16-bit little-endian payload length. |
| 9… | n | `payload` | `payloadLen` bytes. |

A frame is therefore `1 + varintLength + len` bytes. There is **no checksum**. The two length
fields are the only integrity check, and requiring them to agree is what tells a real frame from a
stray `0xaa`. Every frame in the corpus carries a one-byte `len` (the largest is 81 bytes), so the
offsets above are exact for them; a larger `len` shifts every later field by its extra varint bytes.

Two conventions used by the reverse-engineering write-ups:

- The "opcode" label is `(msgType << 8) | cmd`. `0x8106` is `msgType 0x81`, `cmd 0x06`.
- `cmd` is byte 4 and `msgType` byte 5 — **not** one little-endian 16-bit code, which would
  mis-read a `register` frame (`00 85`) as "command `0x8500`".

*Evidence: measured — the layout is reproduced by every frame in
`captures/oneplus-buds-4-2026-10-17/frames.hex`, and the parser asserts that both length fields
describe the bytes present for all 25 (`selfCheck`, "length fields agree").*

### Worked example

`battery-reply` from the corpus, byte by byte:

```
battery-reply = aa 0d 00 00 06 81 03 06 00 00 02 01 14 02 14
```

| Bytes | Field | Value |
|---|---|---|
| `aa` | `start` | sync byte |
| `0d` | `len` | 13 — and exactly 13 bytes follow (`00 00 06 81 03 06 00 00 02 01 14 02 14`) |
| `00` | `b2` | 0 |
| `00` | `b3` | 0 |
| `06` | `cmd` | battery |
| `81` | `msgType` | reply |
| `03` | `seq` | 3 |
| `06 00` | `payloadLen` | 6 little-endian (`0x0006`) |
| `00` | status | `0x00` = the firmware answered |
| `02` | count | two records follow |
| `01 14` | record 1 | slot `0x01` (left), level `0x14` = **20** |
| `02 14` | record 2 | slot `0x02` (right), level `0x14` = **20** |

Decoded: left 20%, right 20%; the case is absent from the report. Opcode label `0x8106`. This
trace is the shape every decoder below follows; the sections below give only the payload layout.

### Message types

| `msgType` | Name | Role |
|---|---|---|
| `0x01` | request | A getter. |
| `0x02` | notification | An unsolicited status push, "family 1". |
| `0x04` | set | A setter. |
| `0x05` | state change | An unsolicited settings push, "family 2". |
| `0x81` | reply | The answer to a request. |
| `0x84` | set ack | The answer to a set. Addressed to the **setter** id. |
| `0x85` | register | Named in the id space; not otherwise used. |

*Evidence: measured — request/reply from every getter, set/`0x84` from `setack-anc`,
`setack-eq`, `setack-basswave`, notification from `notify-devices`, state change from
`eq-push-bass` and `eq-push-balanced`. `0x85` is named in the vendor app's constant table only
(inferred, `dex:` command table) and no `0x85` frame is in the corpus.*

### The status byte

Inside a reply or a family-1 notification body, the first byte is a status:

- `0x00` — the firmware answered; the body follows.
- `0x01` — the firmware declined. The body is not an answer, and a decoder must read **nothing**
  past it. Decoding `[01 03]` as a counted table would invent three records.

Every reply in the corpus leads with `0x00`. The decline value was measured on the hardware while
asking getters the vendor app names — `0x0115` and `0x0116` (hearing enhancement), `0x0119`
(Zen mode) and `0x011d` (free-dialog recovery) — which answer a bare `01` where the battery getter
answers a body. No such declined frame is committed in the corpus, so the decline value is
documented but not cited to a corpus frame.

*Evidence: measured for `0x00` — every reply in
`captures/oneplus-buds-4-2026-10-17/frames.hex`; measured for `0x01` per `Protocol.swift`'s
account of the hardware, not cited to a committed frame.*

---

## Two command namespaces

Getter ids are used in requests (`0x01`) and their replies (`0x81`). Setter ids are used in sets
(`0x04`) and their acknowledgements (`0x84`). They are **not the same numbering**:

- BassWave: getter `0x24`, setter `0x1B`.
- Touch: getter `0x08`, setter `0x01`.
- EQ preset: getter `0x0F`, setter `0x06`. (The `Setter` doc-comment in `Protocol.swift` calls
  EQ the case where setter and getter coincide; the constants in that same file are `0x0F` and
  `0x06`, and the corpus shows both `0x0f` in `eq-reply-bass` and `0x06` in `setack-eq`. This
  document follows the numbers, not the comment.)

Deriving one id from the other looks plausible and simply does nothing. The setter ids are
confirmed by the acks the hardware sends: a set is acknowledged by a `0x84` frame addressed to the
**setter** id, so `setack-anc`, `setack-eq` and `setack-basswave` are hardware evidence for
`0x04`, `0x06` and `0x1B` respectively.

### Getters (requests)

A request is `msgType 0x01` with an empty payload unless noted. The reply body below is what
follows the leading status byte.

| `cmd` | Name | Request payload | Reply body | Evidence |
|---|---|---|---|---|
| `0x00` | HELLO (session opener) | empty | 8 static bytes `ff 77 5a ea 67 0e 20 07` | measured · `hello-reply` |
| `0x05` | firmware | empty | comma-separated ASCII version string | measured · `firmware-reply` |
| `0x06` | battery | empty | `[count]` then `count`×`[slot][level]` | measured · `battery-reply` |
| `0x08` | touch | empty (firmware ignores it) | `[count]` then `count`×`[side][type][gesture][action]` | measured · `touch-reply` |
| `0x09` | wear | empty | `[count]` then `count`×`[slot][flags]` | measured · `wear-reply` |
| `0x0c` | anc (noise mode) | `[0x01, 0x01]` **required** | `[count=1][entry=0x01][mask u16le]`, or the low byte alone | measured · `anc-reply-off` … `anc-reply-adaptive` |
| `0x0d` | miscConfig | `[count]` then feature numbers | — | named only · never sent |
| `0x0f` | eqPreset | empty | `[preset]` | measured · `eq-reply-balanced`, `eq-reply-bass` |
| `0x12` | connectedDevices | empty | `[count]` then device records | measured · `multiconnect-reply` |
| `0x14` | codec | empty | `[codecID]` | measured · `codec-reply` |
| `0x22` | customEQ | empty | `[count]` then the profile, or a bare zero count | measured · `custom-eq-reply` (zero count only) |
| `0x24` | bassWave | empty | `[min][max][current]`, all signed | measured · `basswave-reply-0`, `basswave-reply-2` |
| `0x2f` | capabilities | — | — | named only · never sent |

`0x0d` is `getFeatureSwitchStatus` in the vendor app's own labels, and its request is not a bare
getter — it carries a `[count]` and then the feature numbers to ask about, a list built per model
from their server config. This app has no screen that would need one, so the id stays named and
unsent. `0x2f` is named by nothing on the vendor side and has never been asked here either; it is
kept so the id is not silently this app's own invention.

*Evidence: getters above are measured against the named corpus frames. `0x0d` is inferred
(`dex:` command table, `getFeatureSwitchStatus`); `0x2f` is unconfirmed — nothing observed.*

### Setters

A set is `msgType 0x04`. The ack is `msgType 0x84` with `cmd` equal to the setter id.

| `cmd` | Name | Payload | Ack in corpus | Evidence |
|---|---|---|---|---|
| `0x00` | find (ring) | `[count]` then slot ids | none | inferred · APK `setFindMode` `0x0400` |
| `0x01` | touch | `[count]` then `count`×`[side][type][gesture][action]` | none | record layout measured · `touch-reply`; id is the code constant |
| `0x04` | anc | `[0x01, 0x01, maskLo, maskHi]` | `setack-anc` (`0x0484`) | measured |
| `0x06` | eqPreset | `[preset]` | `setack-eq` (`0x0684`) | measured |
| `0x1b` | bassWave | `[min][max][level]`, all signed | `setack-basswave` (`0x1b84`) | measured |

**The setter-form rule.** For every setter with a getter, the set payload is the getter's reply
payload **minus its leading status byte**, byte for byte:

- ANC reply body `01 01 08 00` → set payload `01 01 08 00` (`setack-anc` answers the matching
  set).
- EQ reply body `02` → set payload `02`.
- BassWave reply body `fb 05 02` → set payload `fb 05 02`.
- Touch reply body `[count] …records` → set payload `[count] …records` (only the changed records
  are sent).

This rule predicts the ANC set's length of 13 bytes (`aa`, one varint byte, seven header bytes,
four payload bytes) and is checked against the captured payloads, not asserted.

`find` has no getter, so the rule does not apply to it: its payload is a count-prefixed id list
(`[01 01]` left, `[01 02]` right, `[02 01 02]` both, `[00]` stop). Those four payloads are
described by the code as measured against the hardware, but **no find frame is committed in this
corpus**.

---

## Reassembly and framing

RFCOMM delivers arbitrary chunks: frames split and coalesce. `drainFrames` in `Protocol.swift`
implements the following, and the corpus replay plus the total-parser test exercise each case.

1. **Resynchronise.** Drop everything before the next `0xaa`. Leading garbage is skipped, not
   fatal.
2. **Wait for two bytes.** Fewer than `sync` + one length byte is a short read, not an error.
3. **A poison varint is stepped over.** Five continuation bytes in a row (`0x80` × 5) can never
   become a value however much more arrives, so if at least six bytes are buffered and bytes
   1…5 all have the high bit set, step over this sync byte and rescan. Waiting here would be
   permanent: the parser would be deaf for the life of the channel.
4. **A truncated varint waits.** `decodeVarint` returning nil for any *other* reason means the
   value is not complete yet; hold the bytes until more arrive.
5. **Sanity-bound the length.** `len` must be at least 7 (the seven header bytes) and at most
   `7 + 0xFFFF` (the payload-length field is 16-bit). Anything else is not a frame boundary; step
   over the sync byte and rescan. The upper bound matters as much as the lower: an overlong varint
   decodes to a length no buffer reaches, which waits forever exactly like a poison byte.
6. **Wait for the whole frame.** `total = 1 + varintLength + len`. If the buffer is shorter, hold
   the partial tail and wait.
7. **Cross-check the two lengths.** Read `payloadLen` from the header; if
   `payloadOffset + 7 + payloadLen == total`, emit the frame and drop `total` bytes. Otherwise the
   two length fields disagree: this was not a frame boundary, so drop the sync byte and rescan.

A partial tail is retained in the caller's buffer (the session owns `rxBuffer`), never in the
protocol layer. A frame that parses must re-parse to itself, and a malformed one yields **no
frame** rather than a decoder fed a length that contradicts the bytes.

*Evidence: measured from the code and verified against `battery-reply`, `eq-reply-bass` and the
two 299-byte synthetic frames in `selfCheck`; a fragmented `firmware-reply` is reassembled in
`Tests/BudsCoreTests/SessionTests.swift`.*

---

## Getter details

Each subsection gives the request, the reply body (after the status byte), the fields decoded, and
the evidence level.

### `0x00` HELLO
Request: empty. Reply: a **static** 8-byte value `ff 77 5a ea 67 0e 20 07` — the same bytes every
session, not a token. OPOv1 class expects this before it will accept commands, so the session
sends it first on open. *Measured · `hello-reply`.*

### `0x05` firmware
Request: empty. Reply: a comma-separated ASCII string, e.g.
`1,2,138,2,2,138,3,1,01,3,2,105`, shown verbatim. It is not a dotted version and this document
does not invent one; the meaning of the comma fields is **not established**. *Measured ·
`firmware-reply`.*

### `0x06` battery
Request: empty. Reply body: `[count]` then `count` × `[slot][level]`.

- `slot`: `0x01` left, `0x02` right, `0x03` enclosure (case).
- `level`: the percent byte; the decoder masks off the top bit (`level & 0x7f`) and treats `0` as
  "reported but unknown" (a slot reads 0 while asleep or shut, and a genuinely flat battery is the
  rarer reading), so a dash is shown rather than a false 0%.
- A slot **absent** from the report is not the same as one reported as unknown: absent slots are
  left alone, present-but-zero slots are cleared.

`battery-reply` carries count 2 — left and right only. The case is never present. *Measured ·
`battery-reply`.*

### `0x08` touch
Request: empty; the firmware ignores the request payload. Reply body: `[count]` then `count` ×
four bytes `[side][type][gesture][action]`, where `side` is `0x01` left or `0x02` right, `type` is
the context (`0x01` media, `0x06` in-call), `gesture` is the physical action and `action` the
function. The vendor app reads the same four bytes in the same order
(`dex:KeyFunctionInfo`). `touch-reply` holds 18 records, and the record walk closes exactly on the
last byte of the payload. *Measured · `touch-reply`.*

### `0x09` wear
Request: empty. Reply body: `[count]` then `count` × `[slot][flags]`. Flags are bits:
`0x01` out of the case, `0x02` in an ear, `0x04` present. The decoder models `0x00` (not present),
`0x04` (in case), `0x05` (out of case — held) and `0x07` (in ear); anything else decodes to
nothing rather than being guessed into a state. The three actually observed by moving the buds
between an ear, a hand and the case are `0x04`, `0x05` and `0x07`. `wear-reply` names all three
slots, including the case at slot 3 — the only evidence the app has that a case exists while the
case is asleep. *Measured · `wear-reply` (shows `0x07` in-ear and `0x04` in-case; the held and
not-present values are described as measured by hand but no corpus frame shows them).*

### `0x0c` anc (noise mode)
Request payload `[0x01, 0x01]` — **required**; the firmware answers nothing at all to a bare
request. Reply body: `[count=1][entryID=0x01][mask u16 little-endian]`. The mode and the level are
the **same field**: the mask *is* the value.

| Mask | Meaning |
|---|---|
| `0x0008` | Off |
| `0x0100` | Transparency |
| `0x0800` | Adaptive |
| `0x0010` | Noise cancellation, High |
| `0x0020` | Noise cancellation, Moderate |
| `0x0040` | Noise cancellation, Low |
| `0x0080` | Noise cancellation, Auto |

An unmodelled mask yields no update. The code describes the ANC status push as **lossy** on this
hardware — some carry the full 16-bit value, others only its low byte, and the low byte of
Transparency (`0x0100`) and Adaptive (`0x0800`) is `0x00` in both, so a one-byte push of `0x00`
would be ambiguous and produces nothing. **No lossy push is committed in this corpus**, so that
behaviour is unconfirmed here; every frame below is a full 16-bit getter reply. *Measured ·
`anc-reply-off`, `anc-reply-nc-high`, `anc-reply-nc-moderate`, `anc-reply-nc-low`,
`anc-reply-nc-auto`, `anc-reply-transparency`, `anc-reply-adaptive` — each set and read back one
at a time.*

### `0x0d` miscConfig
`getFeatureSwitchStatus` per the vendor app's labels. The request carries a `[count]` then the
feature numbers to ask about. **Never sent by this code**; no request, reply or decoder exists for
it. *Inferred · `dex:` command table. Not measured.*

### `0x0f` eqPreset
Request: empty. Reply body: `[preset]`. `0x00` Balanced, `0x01` Clear Vocals, `0x02` Bass,
`0x04` Custom. `0x00` and `0x02` were each set and read back; the other two carry the vendor app's
own preset-table names. `0x03` is skipped by the firmware entirely; `0x04` is the custom slot and
cannot be selected until a profile exists. *Measured · `eq-reply-balanced` (`0x00`),
`eq-reply-bass` (`0x02`).*

### `0x12` connectedDevices
Request: empty. Reply body: `[count]` then `count` records of
`[address 6][length][state][flags][nameLength][name]`:

- `length` equals `3 + nameLength`; both parsers stride by it.
- `state`: `0` not connected, `1` connecting, `2` connected, `4` disconnecting; `3` is absent
  from the vendor numbering and decodes to nil.
- `flags`: bit `0x01` = the entry the buds are talking to on this link (this Mac), bit `0x02` =
  main audio device, bit `0x04` = audio active, bits 3–5 = device type (`1` phone, `2` computer,
  `3` tablet, `4` watch; else none).
- An all-zero address is a placeholder slot and is skipped.

`multiconnect-reply` reads back the same body the `0x0204` push carries, one status byte longer;
the two records begin at body bytes 1 and 35 and consume the 55-byte body exactly, which a wrong
stride would not do. *Measured · `multiconnect-reply`, `notify-devices`. The getter works; there is
no write path.*

### `0x14` codec
Request: empty. Reply body: `[codecID]`. Ids are the vendor app's own list: `01` SBC, `02` AAC,
`03` LDAC, `04` APTX, `05` APTX_HD, `06` APTX_ADAPTIVE, `07` LHDC, `08` LHDC. On the measured unit
the getter answers `02`, which that list calls AAC — **`0x02` is the only id observed on the wire**;
the rest are the vendor list's names. An id outside the list yields no update rather than a near
match. Read-only: the vendor setter `0x041a` is one of the commands its own SDK logs as
unsupported, and it would change the *phone's* link, not the Mac's. *Measured · `codec-reply`.*

### `0x22` customEQ
Request: empty. Reply body: `[count]` then the profile when one exists, or a bare zero count when
none does. Only the first byte past the status is needed to decide whether the custom slot is
selectable. `custom-eq-reply` shows the **no-profile** case (`00 00`); the non-empty profile shape
is **not in the corpus** and its editor is out of scope. *Measured · `custom-eq-reply` (empty
case only).*

### `0x24` bassWave
Request: empty. Reply body: `[min][max][current]`, all signed bytes. The hardware states its own
bounds, which is why the setter takes them as an argument rather than assuming a range; a range
that does not read low-to-high is rejected rather than clamped. On the measured unit the range is
`−5…+5`. *Measured · `basswave-reply-0` (`fb 05 00`) and `basswave-reply-2` (`fb 05 02`).*

### `0x2f` capabilities
Named by nothing on the vendor side and never asked here. Kept so the id is not silently this
app's own invention. *Unconfirmed — nothing observed.*

---

## Setter details

`find` and `touch` are covered in the table above and in "What is not verified". The measured
setters:

### `0x04` anc
Payload `[0x01, 0x01, maskLo, maskHi]`, the getter's reply body minus its status byte. The
explicit 16-bit mask is the only form sent: the field also accepts single-byte conveniences
(`0x01` off, `0x02` cancellation at High, `0x04` transparency), which is why an older single-byte
form appeared to work while mapping to the wrong modes, and which cannot express Adaptive or a
chosen level. *Measured · `setack-anc` (`0x0484`) answers this id; the mask values are pinned by
the `anc-reply-*` read-backs.*

### `0x06` eqPreset
Payload `[preset]`. Selecting the custom slot is refused here until a profile is reported.
*Measured · `setack-eq` (`0x0684`).*

### `0x1b` bassWave
Payload `[min][max][level]`, all signed, clamped to the device's stated bounds. The default
`−5…+5` is a convenience for a caller that has not read the getter, not a claim about every
model. *Measured · `setack-basswave` (`0x1b84`); the payload shape is pinned by
`basswave-reply-2`.*

---

## Pushes and notifications

Two families arrive unprompted. One decoder serves a push and the matching reply, because a push
body is the reply body minus its status byte.

**Family 1** — `cmd 0x04`, `msgType 0x02` (`isStatusNotification`). `payload[0]` selects the
topic and the rest is that topic's reply body with its status byte removed:

| Topic | Means | Evidence |
|---|---|---|
| `0x01` | battery | unconfirmed — the code's constant; no family-1 battery push is committed |
| `0x02` | wear | unconfirmed — the code's constant; no family-1 wear push is committed |
| `0x03` | anc | unconfirmed — the code's constant; the code describes this push as lossy, and no such push is committed |
| `0x06` | the multi-connect table | measured · `notify-devices` |

`notify-devices` is the one family-1 frame committed, and it carries topic `0x06`.

**Family 2** — `msgType 0x05`. The `cmd` byte names the subject on its **own numbering**, which
matches neither the getter nor the setter ids: EQ preset is subject `0x04` (payload: a bare preset
byte), BassWave is subject `0x08` (payload: `[min][max][current]`). The payload equals the getter's
reply payload minus its status byte. *Measured · `eq-push-bass`, `eq-push-balanced` (subject
`0x04`); the subject-`0x08` shape is derived in `selfCheck`, not captured.*

**Sequence bytes.** Replies echo the request's sequence value. The two family-2 pushes in the
corpus carry `0xff`; the family-1 push carries `0x25`. Nothing in the code validates the byte, so
this document does not claim what a push's sequence means.

---

## Which writes the app gates, and on what

Two layers gate every write. The session never assigns a displayed value from its own write: only
a reply changes the screen, so a declined write looks like a control snapping back.

**Protection 1 — the registry** (`devices/*.json`, enforced at load; a bad file fails the build or
launch, it is not skipped):

| Rule | Why |
|---|---|
| A `capabilities` key must be a `Capability` this code models (closed set) | A typo would silently disable a feature, which looks like the model not having it |
| `values` must be enum cases the code can encode or draw | Otherwise the UI offers a button that cannot be honoured |
| A value-bearing capability must have `values`; a non-value one must not | A missing list draws an empty picker; an ignored field is a lie in the file |
| `measured` must cite a `capture` or a `hardware-loop` | "Measured" has to mean a recording exists |
| `inferred` must cite the phone app (`apk`) | "Inferred" means read out of the vendor's code, and nothing else |
| `unconfirmed` must cite nothing (`source: none`) | The word means there is no evidence; a citation would contradict it |
| A `writable` capability must be `measured` | The one that matters most: no write path without a recording behind it |
| Exactly one profile is the `fallback` | An unknown device must have somewhere to land, and only one place |

At runtime a write is allowed only when `spec.writable == true` **and**
`confidence == measured`. That is the whole of `canWrite`.

**Protection 2 — the session.** Each setter additionally checks that the model offers the specific
value, and two setters have a further precondition:

| Setter | Registry gate | Value gate | Extra precondition |
|---|---|---|---|
| `set(mode:)` / `set(ancLevel:)` | `noiseControl` writable+measured | the mode/level is in `values` | reuses the reported level when switching to cancellation |
| `set(eqPreset:)` | `equalizer` writable+measured | the preset is in `values` | custom is refused until a profile is reported |
| `set(bassWave:)` | `bassWave` writable+measured | — | refuses until the device states its bounds |
| `setGesture(_:action:)` | `gestures` writable+measured | the gesture is in `values` | the action must be in the observed set for that gesture |
| `find` / `stopFind` | `findMyEarbuds` writable+measured | — | none on this model (not offered) |

On the shipped measured model, `findMyEarbuds` is `read: false, writable: false` at `inferred`
confidence, so no write path exists for it at all; on the `generic-family` fallback every
capability is `unconfirmed`, so nothing can be written to an uncatalogued device — by construction,
not by caution.

*Evidence: measured — the registry loader and `Session` code as cited; the gating behaviour is
asserted in `Tests/BudsCoreTests/SessionTests.swift` ("An unconfirmed device has no write path at
all").*

---

## What is not verified

This section exists so that no reader can mistake a gap for a feature. Each item is a thing this
document does **not** claim.

1. **The charging case's charge level never appears on this channel.** Across a full capture
   session every `0x8106` reply carried exactly two slots — left and right — even while the wear
   reply named the case (slot 3) on every poll. The case's charge reaches the phone app by some
   path this channel does not show. This is a *measured negative*: `caseBattery` is
   `read: false` at `measured` confidence. The app says "the case hasn't reported a charge" rather
   than drawing an empty battery.

2. **`findMyEarbuds` cannot be confirmed.** The setter exists (`0x0400`, `setFindMode`) and its ack
   `0x8400` has been seen, but that ack is **identical whether or not a tone plays** — every find
   payload tried answered `0x8400` with the single payload byte `[01]`, including requests to ring
   nothing. No capture of a ring session is committed and no ear test was performed. A result byte
   that is `01` in both cases is not evidence that a tone played. Consequently find is `inferred`
   from the APK and has no write path. This is a deliberate regression against the phone app,
   which does have Ring.

3. **Only one model is measured.** Every `measured` frame in this corpus came from one OnePlus
   Buds 4 (firmware `1,2,138,2,2,138,3,1,01,3,2,105`). Every other model in the registry is the
   `generic-family` fallback: everything `unconfirmed`, read-only, with no write path anywhere.

4. **Prompt volume.** The prompt-volume scale was not measured, so **no control is exposed**. In
   fact there is no prompt-volume command id, request or decoder in `Protocol.swift` at all — the
   README's "getter measured; scale unmeasured" is not backed by any code path here, and this
   document does not present one. The vendor prompt-voice *upload* is a file transfer and is out of
   scope (`SCOPE.md` §4).

5. **Firmware updates are permanently out of scope.** They travel on a separate service — BESOTA,
   RFCOMM channel 13 — which is never opened: not for discovery, not for testing. There is no OTA
   UI, no OTA code path and no OTA decoder.

6. **The gesture setter's acceptance is not shown by a frame here.** No `setack-touch` frame is in
   this corpus; the only committed hardware acks are for the ANC, EQ and BassWave setters. That the
   firmware accepts a re-sent record rests on the code's `Setter` constant `0x01` and the record
   layout from `touch-reply`, not on an ack in `frames.hex`.

7. **Multi-connect write is unmeasured.** The vendor SDK implements a setter
   (`0x0429`, `operateMultiConnectHandheldDevice`), but it has never been exercised on this
   hardware and no capture shows it, so `multipoint` is `read: true, writable: false`.

8. **The codec is read-only and its setter is unsupported.** The vendor setter (`0x041a`,
   `setHighAudioCodecType`) is one of the commands its own SDK logs as unsupported, and writing a
   codec would change the *phone's* link, not the Mac's.

9. **The in-call gesture context is not offered.** Its action codes (`type 0x06`) are unnamed in
   every published description of this protocol, and guessing between "answer" and "decline" risks
   ending someone's call.

10. **The non-empty custom-EQ profile shape is not in the corpus.** Only the "no saved profile"
    reply (`00 00`) was captured; the profile editor is out of scope.

11. **The battery charging flag is not in the corpus.** No captured battery frame sets the top bit
    that the code masks off (`level & 0x7f`) and describes as a charging flag; that reading comes
    from the code, not from a committed frame.

12. **`0x0d` (miscConfig) and `0x2f` (capabilities) are named but never sent.** Nothing was
    measured for either; `0x2f` in particular is named by nothing on the vendor side.

13. **The wear states out-of-case (`0x05`) and not-present (`0x00`) are not in the corpus.** The
    captured wear reply shows only in-ear (`0x07`) and in-case (`0x04`); the other two values are
    described as measured by hand-moving the buds, with no frame committed.

14. **`b2`/`b3` (bytes 2 and 3) are always `0x00` but their purpose is not established.** Every
    frame in the corpus has them zero; this document does not claim what they mean.

15. **The firmware string's fields are not decoded.** It is shown verbatim; the meaning of its
    comma-separated components is not established.

16. **Find's payloads (`[01 01]`, `[01 02]`, `[02 01 02]`, `[00]`) are not in the corpus.** The
    code describes them as measured against the hardware, but no find frame is committed.

17. **Only family-1 push topic `0x06` is in the corpus.** The mapping of `0x01` to battery, `0x02`
    to wear and `0x03` to anc is the code's constant with no committed frame behind it, and topics
    beyond those four are unknown.

18. **The lossy ANC push is not in the corpus.** The code describes some ANC pushes as carrying
    only the low byte — whose `0x00` cannot tell Transparency from Adaptive — but every ANC frame
    committed here is a full 16-bit getter reply. The lossy path is exercised by derived frames in
    `selfCheck`, not by the hardware recording.

Nothing in this list is "not yet". Items 5 and the prompt-voice upload are permanently out of
scope; the rest are open questions that a capture or a hardware loop could close.

---

## Provenance

- **The wire, byte for byte:** `captures/oneplus-buds-4-2026-10-17/frames.hex`, taken from one
  OnePlus Buds 4 with the single-device app built with `BUDSBAR_TRACE=1` and `BUDSBAR_HARVEST=1`.
  Only received frames are kept in that file; what the app *sends* is the other half of the
  protocol and is reconstructed by `BudsProtocol`'s encoders, which the self-check pins against
  those received frames and against the hardware acks.
- **Names and ids that were not on the wire:** the vendor app `com.heytap.headset` 116.9.0, read
  with JADX to a scratch directory outside this repository. Each such reading is cited to a class
  and method; the capture always wins an argument with it.
- **No redistribution.** No vendor code, asset, font, icon or extracted JSON appears in this
  repository or in any release. Every visual is drawn by code here. The licence covers this
  repository's source only and grants no rights to the vendor's software, trademarks or assets.

See `../capture/README.md` for the full provenance record and `../SCOPE.md` for the legal posture.
