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
- The sibling repository contains a protocol core (`OnePlusBuds4Mac:Sources/BudsBarKit/Protocol.swift`,
  1523 lines) that is not model-specific at all: it is pure functions over `[UInt8]`, imports only
  `Foundation` and `os`, and its only link to the corpus is a single line that injects
  `FixtureCorpus.frames`.
- The generic plan already existed as a written spec (the `heymelody-master-prompt.md` kept outside
  this repository, 314 lines) and had never been turned into code or a repository.

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

---

## D5 — Find-my-earbuds is not offered on the OnePlus Buds 4, even though the phone app has it

**Date:** 2026-10-18

**Options**

1. Offer Ring and Stop on the measured model, because the app that ships today offers them and
   the setter has been exercised on real hardware.
2. Mark the capability `inferred` from the reference app's code and offer nothing, so no write
   path exists until there is a recording and an ear test.
3. Mark it `measured` with a `hardware-loop` citation, on the strength of the acks that came back.

**Evidence**

- The setter is real and is the vendor's own: `0x0400 setFindMode`, and the ack `0x8400` has been
  observed answering with a single result byte.
- The ack **does not distinguish accept from reject**. Every find payload tried — five of them —
  answered `0x8400` with the payload `[01]`, including the ones that were asked to ring nothing.
- No capture of a ring session was committed, and the ear test that would settle whether a tone
  actually plays was deliberately skipped.
- "Stop" has no frame of its own at all: the only stop this vocabulary can express is the find
  setter with an empty slot list, and nothing in the captures shows the firmware honouring it.

**Decision:** option 2. `findMyEarbuds` is `read: false`, `writable: false`, `confidence:
inferred`, citing `dex:…i#setFindMode`.

**Why:** option 3 would be the lie this project is built to avoid. "Measured" has to mean an
observation that can tell success from failure, and this ack cannot: a result byte that is `01`
whether or not a tone played is not evidence that a tone played. Option 1 ships a button whose
only feedback is the user's own ears, in an app that claims its writes are verified — which is
exactly the kind of claim the rest of this repository refuses to make.

This is a real, acknowledged **regression against the app that ships today**. It is written down
rather than hidden: `README.md`'s support matrix has no row for it, and this entry is the reason.

**What would change our mind:** a committed recording of a ring — the request and the hardware's
answer with something in it that distinguishes the two cases — plus one ear test, or an ack whose
semantics are established rather than assumed. Then it becomes `measured` with a write path, and
the app grows a Ring button.

---

## D6 — The session owns no timer; the host drives `poll()`

**Date:** 2026-10-18

**Options**

1. Keep the single-device app's shape: `Session` installs its own `Timer` and schedules its own
   deferred read-backs with `DispatchQueue.main.asyncAfter`.
2. `Session` exposes `poll()`, and nothing else; the host (the app, or a CLI) owns the clock.

**Evidence**

- The master prompt's trap list includes "a headless CLI must pump the run loop, not `sleep`, or
  the delegate callbacks never fire", and its Phase 6 requires that `Session` be "deterministic
  and inspectable".
- The single-device app's `refreshAfterSet()` re-reads at 0.35 s and 1.2 s with two timers. That
  behaviour is untestable without waiting, and it made `swift test` time-dependent.
- `SessionTests` now asserts write-then-read-back, give-up-after-N-polls and a fragmented frame
  reassembling, all in milliseconds, with no radio.

**Decision:** option 2, with the deferred read-back modelled as a tick count: a write asks for its
read-back immediately *and* marks the next two polls as read-back polls, so a late answer still
lands and an absent one is eventually given up on rather than left pending forever.

**Why:** a clock inside the session is the difference between a state machine that can be tested
and one that can only be watched. It also keeps `BudsCore` host-generic: `Timer` and `Dispatch`
are platform furniture, and neither belongs in the layer that is meant to be shared byte for byte
across three operating systems.

**What would change our mind:** nothing plausible. If a host forgets to poll, the symptom is a
stale reading, which is visible and is already the thing the UI must render honestly.

---

## D7 — The app icon is an equalizer mark, not an earbud

**Date:** 2026-10-18

**Options**

1. Draw the product: one or two earbuds on the dark squircle.
2. Draw the category: an equalizer, because that is the first thing anyone opens this app for.
3. Ship no icon, or a monogram.

**Evidence**

- Five revisions drew an earbud literally, and each was rendered at 16, 32 and 128 points and
  looked at rather than assumed. Every one read as a different object: a tall capsule on a stem is
  a **microphone**; a circle on a stem is a **person**; two of those leaning apart are a **green
  smudge** at 16 points; a squat body with a nozzle is a **hand mirror**; the same pair with the
  nozzles turned outward is **two crowns**.
- That is a property of the shape, not of the drawing. An earbud *is* a blob on a stick — so is a
  lollipop, a pin, a microphone and a mirror — and at 16 points there is nothing left to separate
  them. The literal option was not a larger amount of care away from working; it was unwinnable at
  that size.
- The first render that measured correctly put the mark at 49.9% × 49.6% of the tile. Every
  earlier version had been exactly one icon-inset (100 points at 1024) down and to the right,
  because the art used canvas coordinates inside a content-box coordinate space. It was found by
  measuring the pixels, not by looking harder.

**Decision:** option 2 — three unequal bars, the middle one tallest.

**Why:** an icon's job is to be recognised in a Dock, and three strokes cannot be confused with
anything at 16 points, while a smudge can be confused with everything. The bars are also true of
this app rather than aspirational about it: changing the equalizer and the noise mode is the first
thing anyone opens it for. An icon that promises earbuds and delivers a microphone is a small
version of the same failure this whole repository is arranged to avoid.

The five failed revisions are written into `Tools/make-icon.swift` as a table rather than deleted,
because the next person to think "this should obviously be an earbud" is going to try it, and the
record is what stops that being a weekend.

**What would change our mind:** a literal earbud that survives a 16-point render and reads as one
in a Dock context — which means an actual illustration by someone who draws for a living, not
another arrangement of two ellipses and a rounded rectangle.

---

## D8 — The site answers five questions and refuses to be a model catalogue

**Date:** 2026-10-19

**Options**

1. A landing page plus one page per model in the family — forty-odd device-name pages — which is
   what a site in this category looks like from the outside.
2. Five pages, each one the best available answer to a question people actually type: the app
   itself, the one measured model, why macOS cannot do this and what to do instead, an honest
   comparison with the phone app, and one supported-models page.

**Evidence**

- Searching for `oneplus buds mac app` returns an Android-emulator page claiming to run the phone
  app on a PC, the App Store listing for the *iPhone* app, a vendor forum thread and YouTube
  videos. Nothing on the first page is a Mac app.
- Searching for `how to change oneplus buds eq on mac` returns forum threads and videos **asking
  the question**, and no page answering it.
- The nearest existing thing is an MIT-licensed realme TWS controller on GitHub, four stars, no
  description, last touched months ago.
- Google restricted `FAQPage` rich results in 2023 to a small set of authoritative sites and
  deprecated `HowTo` results entirely. Both are still read by Bing and by answer engines, which is
  why they are emitted and why nothing depends on them.

**Decision:** option 2.

**Why:** the incumbents are a dormant repository, an emulator-spam page and a personal blog post,
so the transactional queries are winnable — but only by being the specific, correct answer. A new
domain publishing forty thin pages of model names is the textbook doorway pattern: it will not
rank, and here it would be worse than not ranking, because each page would imply support for
hardware nobody has recorded. This project's one real asset is that its claims are checkable, and
a model catalogue is exactly the thing that would spend it.

The same reasoning disposed of the obvious comparison-page move. The page about the phone app says
the App Store offers it for Apple silicon Macs in some storefronts, and that whether it can reach
the control channel from there **has not been tested**. That is a weaker sentence than "it does not
work on a Mac", and it is the only one this project is entitled to write.

**What would change our mind:** a model becomes measured. Then it earns its own page, because there
is real model-specific content to write — the OnePlus Buds 4 page exists because that hardware has
been recorded, not because the name was available.

---

## D9 — The site's FAQ markup is generated from the FAQ the page shows

**Date:** 2026-10-19

**Options**

1. Write the `FAQPage` structured data by hand, as prose that improves on the visible FAQ: fuller
   answers, sharper questions, the kind of phrasing an answer engine prefers.
2. Write the FAQ a reader sees, and generate the structured data from it, so the markup is a copy
   of the page rather than a version of it.

**Evidence**

- Every page carried both, and on every page they disagreed. The home page marked up *"Can I change
  noise cancelling on OnePlus, OPPO or realme earbuds from a Mac?"* while showing *"Can I change
  noise cancelling on these earbuds from a Mac?"*; the OnePlus Buds 4 page marked up four questions
  and showed three different ones; the supported-models page marked up three questions and had no
  visible FAQ at all.
- Google restricted `FAQPage` rich results in 2023 and deprecated `HowTo` results entirely, but the
  markup is still read by Bing and by answer engines — which is why D8 emits it. That leaves the
  failure mode with no upside: the 2023 rules require marked-up content to be visible to the reader,
  so a page whose markup outruns the page carries the spam signal and collects none of the reward.
- The two diverged because they were maintained as two documents about the same thing, which is the
  same defect as a registry note that describes a frame no capture contains. That one is already
  unforgeable: the claim has to name bytes. This one had nothing to name.

**Decision:** option 2. The visible `<dl class="faq">` is the source. `Tools/faq-jsonld.py` rewrites
each page's `mainEntity` to quote it — same questions, same order, same answers, verbatim — and
`DocumentationTests` fails if the two ever differ, or if a page marks up a FAQ with no visible copy
to quote.

Where the two disagreed on substance, the fuller answer moved onto the page rather than the terser
one moving into the markup. The Audio MIDI Setup question, the emulator answer and the wording of
the case-battery answer were all content the marked-up copy had and the visible FAQ did not, and the
right response to "the page is worse than its own metadata" is to improve the page.

**Why:** paraphrase is where a claim goes to grow. A marked-up question that no visitor can read is
the same kind of error as a write path with no capture behind it, and this project's whole argument
is that it does not make that error. Generating the markup also removes the second document, so
there is nothing left to keep in step by hand.

**What would change our mind:** the markup becoming a liability rather than an asset — if the
engines stop reading it, the `FAQPage` block is deleted. The FAQ stays either way, because the FAQ
is for people.
