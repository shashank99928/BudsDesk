# Decisions

Every entry: the options considered, what the evidence showed, what was chosen, and what would
change our mind. Newest last.

---

## D1 — BudsDesk is a separate repository, not a branch of the OnePlus Buds 4 app

**Date:** 2026-10-18

**Options**

1. Make the existing `OnePlusBuds4Mac` app generic in place (rename it, add a capability
   registry, ship one app for every model).
2. Start a new repository, `BudsDesk`, that supports the whole family, and leave
   `OnePlusBuds4Mac` as the model-specific app that already ships.

**Evidence**

- `OnePlusBuds4Mac` is a shipping product with a name, a bundle identifier, a site, a DMG and a
  release history. Its value is that it is honest about *one* device: it says "OnePlus Buds 4"
  everywhere and its README claims exactly what has been measured on that unit.
- The same repository contains a protocol core (`Sources/BudsBarKit/Protocol.swift`, 1523 lines)
  that is not model-specific at all: it is pure functions over `[UInt8]`, imports only
  `Foundation` and `os`, and its only link to the corpus is a single line that injects
  `FixtureCorpus.frames`.
- The generic plan already existed as a written spec (`heymelody-master-prompt.md`, 314 lines)
  and had never been turned into code or a repository.

**Decision:** option 2. New repository, `BudsDesk`. `OnePlusBuds4Mac` keeps shipping unchanged.

**Why:** renaming the shipping app in place would invalidate its release history, its site, its
bundle identifier and its signed DMGs to gain nothing but a shorter list of repositories. The
protocol core is already cleanly separable, so a new repository costs one file of duplication and
buys a device-generic architecture that the single-device app never needed.

**What would change our mind:** if BudsDesk reaches parity with `OnePlusBuds4Mac` on the OnePlus
Buds 4, `OnePlusBuds4Mac` may be retired to a pointer README — but only after BudsDesk has a
release that is verified on that hardware, not before.

---

## D2 — Port the verified core; do not rediscover it

**Date:** 2026-10-18

**Options**

1. Follow the master prompt's phases literally and re-derive the framing, the command ids and
   the decoders from the captures and the APK a second time.
2. Port the already-verified protocol core out of `OnePlusBuds4Mac`, generalising the parts that
   were single-model, and keep its captures as the first capture in the new corpus.

**Evidence**

- The core's decoders are covered by 182 self-check assertions and 25 frozen captures, and the
  setters are proved against real hardware acks in that self-check (`setack-anc`, `setack-eq`,
  `setack-basswave`, `setack-touch`).
- The master prompt's own Phase 3 says the project's measurements exist "to skip rediscovery".

**Decision:** option 2. Port, then generalise. Re-measure only what was single-model.

**Why:** re-deriving a verified protocol risks introducing a *new* error into a layer that
currently has none, and the only thing to gain is tidiness. The capture is the fixture, and the
capture is being carried across intact.

**What would change our mind:** if a ported decoder's behaviour differs from the original under
the corpus replay test, the port is wrong and gets fixed — the corpus arbitrates, always.

---

## D3 — The corpus becomes many captures, each with provenance

**Date:** 2026-10-18

**Options**

1. Keep one flat file, `Tests/Fixtures/buds4-frames.hex`, exactly as the single-device app has it.
2. One directory per capture: `captures/<capture-id>/frames.hex` plus `capture.json`, and a
   generator that folds them all into one Swift corpus with the provenance attached to every
   frame.

**Evidence**

- The master prompt's non-negotiable 1 defines a fixture as "a recording with provenance (device
  model, firmware string, capture tool, date, channel)". A flat file carries that only in prose
  comments, and a second model's frames would sit in the same file with no machine-readable way
  to tell them apart.
- The single-device app already keeps provenance in the header comment, which is exactly the
  information that must become a field the moment there is more than one device.

**Decision:** option 2.

**Why:** the moment a second model is added, "which device did this frame come from" stops being
decoration and becomes the difference between a correct decoder and a plausible one. Making it a
field now costs one generator change.

**What would change our mind:** nothing plausible. The frames themselves are unchanged; only the
container is.

---

## D4 — `devices/*.json` is generated from evidence, and the file says what it cannot know

**Date:** 2026-10-18

**Options**

1. Hand-write capability files and keep them tidy by hand.
2. Write them from the measured evidence, with a `confidence` per capability and an explicit
   `evidence` field naming the capture or the command that established it.

**Evidence**

- The single-device app's README is full of sentences of the form "this is measured" and "this
  has never been seen", which is the same information the registry needs.

**Decision:** option 2, and a capability with no evidence is not written at all rather than
written as `unconfirmed` with nothing behind it — unless it is a capability the *protocol* clearly
has and this model's support for is genuinely unknown, which is a different statement and gets
`unconfirmed`.

**What would change our mind:** a model whose capability report the hardware itself sends (a
capability getter that answers) makes the registry derived rather than asserted for that model.
Then the file records what the device said, and its `source` says so.
