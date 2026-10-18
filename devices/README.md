# The capability registry

One JSON file per model. This is what makes the app device-generic: a control is drawn because a
file says the model has it, not because the code branches on a model name.

Adding a model is adding a file. It is not a build, and it does not require the code to know the
model exists.

## Format

```jsonc
{
  "id": "oneplus-buds-4",              // must equal the file name without .json
  "model": "OnePlus Buds 4",           // what a person calls it
  "vendor": "OnePlus",
  "notes": "…",                        // optional prose

  "match": {
    "names": ["OnePlus Buds 4"],       // exact, case-insensitive, against the OS's name
    "namePrefixes": ["OPPO Enco"],     // optional, for regional generation suffixes
    "serviceUUIDs": ["0000799a-d102-11e1-9b23-00025b00a5a5"],
    "fallback": false                  // exactly one profile in the registry sets this
  },

  "capabilities": {
    "bassWave": {
      "read": true,                    // does the device report / can the app act on it
      "writable": true,                // does the app offer a write path
      "confidence": "measured",        // measured | inferred | unconfirmed
      "evidence": { "source": "capture", "ref": "basswave-reply-2", "note": "…" },
      "values": ["…"],                 // only for value-bearing capabilities
      "note": "…"                      // optional prose
    }
  }
}
```

`serviceUUIDs` is the **gate**, not the key: every member of the family advertises the control
service, so it decides whether a device is a candidate at all. Identity comes from `names` first,
then `namePrefixes`, then `fallback`.

## The rules the loader enforces

These are not conventions. A file that breaks one of them **fails to load**, and the error names
the profile and the capability. A registry that loads and does nothing is worse than one that
stops the build, because it looks like support.

| Rule | Why |
|---|---|
| A `capabilities` key must be a capability this code models | A typo would silently disable a feature, which is indistinguishable from the model not having it |
| `values` entries must be enum cases the code can encode or draw | Otherwise the UI offers a button that cannot be honoured |
| A value-bearing capability must have `values` | A missing list draws an empty picker, which reads as "your device supports nothing" |
| A capability that takes no values must not have `values` | It would be ignored, and a field that does nothing is a lie in the file |
| `measured` must cite a `capture` or a `hardware-loop` | "Measured" has to mean a recording exists |
| `inferred` must cite the reference app (`apk`) | "Inferred" means read out of the vendor's code, and nothing else |
| `unconfirmed` must cite nothing (`source: "none"`) | The word means there is no evidence; a citation would contradict it |
| A `writable` capability must be `measured` | This is the one that matters most: no write path without a recording behind it |
| Every measured or inferred claim carries a note | A finding states what it rests on |
| Exactly one profile is the `fallback` | An unknown device must have somewhere to land, and only one place |

`read: false` is not an error, and is often a **finding**: `caseBattery` on the OnePlus Buds 4 is
`read: false` at `measured` confidence, because a full session's recordings show it is never
reported on this channel. That is a measured negative, which is why it is allowed to be measured.

Test coverage lives in `Tests/BudsCoreTests/RegistryTests.swift`, including a test that
takes the shipped profile, breaks one claim, and asserts the failure is the *named* one.

## Coverage today

| Profile | Confidence | Evidence |
|---|---|---|
| `oneplus-buds-4.json` | measured | `captures/oneplus-buds-4-2026-10-17` |
| `generic-family.json` | unconfirmed | none — this is the fallback for a model nobody has recorded |

## What the registry deliberately does *not* hold

- **BassWave's range.** The device reports it in its own getter (`bassWaveBounds`), and the setter
  writes back what it was given. A registry that restated the range would be a second, staler copy
  that could disagree with the hardware.
- **Anything a getter already reports.** Firmware string, codec, battery levels, wear state and
  the multi-connect table are read at runtime. The registry only says whether to expect them.
