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

---

## D10 — The screenshot on the site is a drawing of the app, made by the app

**Date:** 2026-10-19

**Options**

1. Take a screenshot of the running app. It is the obvious thing, and it needs the hardware awake
   and paired at the moment of capture.
2. Draw the window off-screen, at a fixed size, from the recording in the corpus — the real
   `DeviceWindow` over the real `AppModel`, with the replay named in the window's own footer.
3. Commission or compose an illustration of what the app would look like.

**Evidence**

- Option 1 was not available and will not always be: the measured pair is asleep in its case, and a
  site whose image can only be produced when hardware is on the desk is a site nobody else can
  reproduce. It also has a worse failure mode than being unavailable — a screenshot of a *stale*
  build looks exactly like a screenshot of the current one.
- Option 3 is the one this project can never take. An illustration of a measured app is a picture of
  a claim, and there would be nothing to check it against.
- Option 2 turned out to be a test as well as a picture. Drawing `away` (nothing paired, registry
  loaded) for the first time showed the window saying **"No capability registry — the registry could
  not be read, so nothing can be offered"** — which is what a user sees on their first launch, and
  is false. The card for "broken install" was being drawn for "no earbuds yet". That is a
  user-visible bug on the most common first run, and it was found by drawing the app rather than by
  using it, because using it meant the earbuds were already paired.
- `ImageRenderer` cannot rasterise a `ScrollView` on this OS — it produced a blank rectangle. A
  hosted `NSView` drawn with `cacheDisplay` can, at a stated scale, and the two AppKit-backed
  controls (a gesture `Menu`, an indeterminate `ProgressView`) are swapped for static labels by an
  environment flag, because an animation has no still.

**Decision:** option 2, and the drawings live in the repository where they can fail a build. The
site's image is `docs/assets/connected.png`, which `--render` writes and `--compare` verifies, so
the picture a visitor sees is a picture that passed. `build.sh` runs `--compare` against the release
binary, and a missing drawing is a failure rather than a silent write — a build must not rewrite the
thing it is checking.

**Why:** it is the same rule as everywhere else here, applied to pixels: the artefact has to be
produced by the thing it claims to be. A drawing is honest about what it is, too — the footer names
the recording being replayed, so the picture carries its provenance instead of implying someone's
desk. And it turns a marketing asset into a regression test: the clipped label and the control that
fell out of its row are exactly the failures a compiler cannot see.

**What would change our mind:** a still cannot show a flow, and if the site ever needs to show one
(the pairing, the moment the earbuds wake up) a screen recording would be the right artefact —
labelled, and made the same way, driven by a recording rather than by a wish.

---

## D11 — One page per brand, because each brand explains something the others do not

**Date:** 2026-10-19

**Options**

1. Publish no brand pages. D8 settled on five pages, one per question people type, and "a page per
   brand" is the same move as "a page per model" with a larger step size.
2. Three pages — OnePlus Buds, OPPO Enco, realme Buds — each saying what that brand's owner gets on a
   Mac today, and each linked from the navigation on every page.

**Evidence**

- The three winnable query families in D8's survey are brand-shaped: `oneplus buds mac app`,
  `oppo buds mac app`, `realme buds mac app`. The generic phrasing (`control earbuds from mac
  bluetooth`) is not winnable; the brand name is the part somebody actually types.
- Each brand carries a fact that is true of it and not of the other two, and every one of those facts
  is already in this repository: OnePlus has the single measured model; the control service is named
  `enco link` and the RFCOMM channel is read out of the device's own SDP record rather than
  assumed (`Sources/BudsDeskMac/RFCOMMTransport.swift`); and the SDP record on some realme models
  carries a second channel named `Realme Pearl` (`capture/README.md`) — which is also why a realme
  owner should be told an independent realme Mac client exists before they decide anything.
- The failure this guards against is measurable rather than hypothetical: three pages differing only
  in the brand word are D8's forty-page catalogue three pages smaller, and the trade would be the one
  thing this site has — claims a reader can check — for three pages saying nothing new.

**Decision:** option 2: `docs/oneplus-buds-on-mac.html`, `docs/oppo-buds-on-mac.html`,
`docs/realme-buds-on-mac.html`, in the navigation of every page. Three tests hold them: the
navigation is identical on every page and reaches every brand; each brand page carries the download
and links the model list; and a brand with no measured model has to contain the words `read-only`, so
the limit cannot be dropped in an edit that reads well.

**Why:** a brand page earns its place exactly when the brand explains something. That a family member
connects and cannot write is what this project is about, and each brand has its own reason for it —
OnePlus because a recording exists for one of its models, OPPO because the channel is named after it,
realme because the channels are not uniform even inside the family. None of those sentences can be
swapped into another brand's page, which is the test a doorway page fails.

**What would change our mind:** a brand page that says nothing its siblings do not. Then it is
deleted rather than improved, because that is what a doorway page is. And the moment a second model
is measured, that model earns its own page (D8) and the brand page becomes the hub linking to it —
which is already the shape of the OnePlus page around `oneplus-buds-4.html`.

---

## D12 — The site's rules follow the pointer and the viewport, not the machine it was built on

**Date:** 2026-10-19

**Options**

1. Keep the stylesheet tuned for the desktop the site was designed on: hover styles unconditional,
   `white-space: nowrap` on the short status cells in the model tables, the brand cards linked by
   their headings only.
2. Declare hover only where a pointer exists, let the status cells wrap, make the whole card the
   link, and keep the sticky header from covering the skip link's target.

**Evidence**

- The status cells held phrases like "Read-only until recorded", set `nowrap`. At 320px or at 200%
  zoom the three columns' minimum widths exceeded the viewport, so the table scrolled sideways with
  nothing on screen to say so — the shape of a table whose last column is unreachable. Wrapping costs
  nothing at 940px, where the column has room and does not wrap at all.
- On a touch screen a bare `:hover` sticks to the last link tapped, so `nav.site a:hover` left a
  navigation link looking permanently current next to the real `aria-current` one.
- The skip link is the first focusable element on every page, and its target sat under the sticky
  header — which is the one thing a skip link must not do.
- The brand cards' headings were links inside bordered cards, so the card looked pressable and only
  its first line was.

**Decision:** option 2. Hover rules live inside `@media (hover: hover)`; the status cells wrap;
`a.card` is the link and the heading inside it takes the accent colour; `main` carries a
`scroll-margin-top` clearing the header; images keep `pointer-events: none`, which is a deliberate
choice of this project rather than an oversight — they are diagrams, and nothing here should be
openable in a new tab.

**Why:** every one of these is a rule that only holds on the machine the page was looked at on. The
site is read on a phone as often as a laptop, and at 200% zoom by people who need it. None of the
four costs anything on the desktop, and the stylesheet stays one auditable file with no dependency
added — which is the constraint that makes the rest of these decisions possible.

**What would change our mind:** none of this is load-bearing enough to defend against evidence. If a
wrapped status cell ever reads worse than a clipped column, the cells get a fixed width and the
wrapper gets a visible scroll cue instead of the wrap.

---

## D13 — A stated fact needs a citation, and a tool may only write what it can see

**Date:** 2026-10-19

**Options**

1. Keep protocol facts in prose and let the recording be the de-facto authority. A fact's
   provenance is then whatever the last person to edit the file believed.
2. One ledger (`EVIDENCE.md`): a row per fact, a confidence of `measured` / `inferred` /
   `unconfirmed`, and a citation to a byte offset, a class and method, or a frame — plus the rule
   that an ingest tool writes `null` for anything it cannot itself observe.

**Evidence**

- The control service UUID was wrong in 13 published places, and the *string* form of that
  constant had been wrong since it was written. The byte form — the half that opens the channel —
  was right, so nothing ever failed; the string form — the half that gets published — differed by
  one digit. Runtime behaviour was identical and completely misleading.
- The registry's own gate could not catch it, and still cannot: it compares the registry's UUIDs
  against the same constant in the same binary, so a self-consistent pair of errors agreed with
  itself forever. Only a witness outside the repository can break that.
- The wrong value was not mis-transcribed from a measurement. It was a literal in the manifest
  template of `Tools/trace-to-capture.py`, next to a service name that also appears nowhere else.
  The recording inherited both, and the recording then became the citation for the protocol spec,
  the registry, the docs and the site. A field labelled measured had a writer, not a witness.
- Two witnesses settled it in one afternoon: the earbuds' own SDP record
  (`capture/sdp-oneplus-buds-4-2026-10-19.txt`) and the APK's raw string pool
  (`classes.dex:0x6a6bbe`, found with `Tools/dex-strings.py`, which does not decompile). Both say
  `0000079a-…`. The repository was the outlier.

**Decision:** option 2. Facts live in `EVIDENCE.md` with a confidence and a citation that a
stranger can reproduce from the same file and hash. `Tools/trace-to-capture.py` now writes `null`
for the service name and the channel, with the reason in a comment beside it. And two tests hold the
line: the two forms of the constant must agree with each other *and* with the value read off the
hardware, and every published copy of it — registry, corpus, spec, docs — must match.

**Why:** a wrong fact that is consistent with itself is invisible to every test that checks
consistency, which is most of them. This project's whole claim is that its facts came off a wire,
and the ledger is what makes the difference between a fact and a recollection visible while it is
still cheap to fix.

**What would change our mind:** nothing about the need for citations. A row whose citation nobody
else can reproduce is wrong and gets deleted rather than softened, and a fact that only the author
can verify belongs in the open questions, not in the table.
