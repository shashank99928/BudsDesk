# Changelog

Notable changes, newest first. This project follows [Keep a Changelog](https://keepachangelog.com/)
and [Semantic Versioning](https://semver.org/).

The honesty rule applies here as everywhere else: a version is not described as supporting a model
unless that model was measured. What is listed as *not* included is as deliberate as what is.

## [Unreleased]

### Changed

- **The site is a product page now.** It was a dark document of the project's reasoning; it is
  a plain bar, one first screen with the app's own window in it, and the argument in sections:
  what it does, what it will not do, which models work, how to install, and the questions. The
  capability table, the registry's rules and the recipe for adding a model are unchanged and
  still say what they said.
- **The recording is on the page.** A new section shows eight frames off a real OnePlus Buds 4,
  which a visitor can pick through, each with the note that came with it in the capture. The
  bytes are generated from `captures/oneplus-buds-4-2026-10-17/frames.hex` by
  `Tools/capture-html.py` and a test holds the page to that file, so the site cannot quote a
  frame the recording does not contain.
- **The page is light, and follows the system.** The app is pinned to Dark Aqua because that is
  the appearance it was verified in; the page is not an app, and it is now light with a dark
  scheme for a system that asks for one. The accent is still the app's own blue, darkened in the
  light scheme until the running text clears 7:1 against the ground.
- **Everything arrives in pieces.** Each section's heading, text and picture rise into place as
  the section arrives, and the whole layer is dropped under Reduce Motion. With the script
  blocked, the page is the same page with nothing hidden: the mark that hides the animation is
  taken back off if the script that runs it never arrives.

### Added

- **`Tools/capture-html.py`**, which writes the site's frames section out of the capture file
  rather than out of a transcription of it, and **`Tools/refresh-chrome.py`**, which puts the
  bar and the footer on every page in one place instead of one copy per page.

### Verified

- 182 protocol checks (the self-check), 28 SF Symbol names, 25 recorded frames from one model,
  and 60 tests.

## [0.1.2] — 2026-10-19

### Changed

- **The window answers the pointer.** Every control used `.buttonStyle(.plain)`, which on macOS
  draws nothing while a button is held, so a pressed control looked identical to one that was not.
  The pills, Disconnect, the BassWave steppers and the log toggle now compress to 0.96 on a 150 ms
  ease-out curve — the same curve selection uses, so pressing and selecting do not fight.
- **Cards are concentric.** The card's outer radius is the inner radius plus its own padding (24pt
  over 10pt at 14pt of padding). Two curves of the same radius, one nested in the other, read as
  thicker on the inside than the outside.
- **The log says what it will draw.** "Show N lines" described a box that draws the newest 60, and
  the number changed the button's width as it grew. It now says "Show the last 60 of 214 lines",
  uses tabular digits, opens scrolled to the newest line, has an empty state, a hit target and
  border to match the other controls, a tooltip, and ⌘L.
- **The site uses the app's own icon in its header**, one flat accent on the primary button instead
  of a gradient whose second blue belonged to nothing else, and the app's muted/faint values
  instead of two that had drifted. The primary button's ink measured 3.86:1 and now measures 7.6:1.

### Fixed

- **Reduce Motion was ignored.** The flag was read by a helper struct that draws nothing, and
  `@Environment` is filled in only while a view updates — so the app animated for anyone who had
  asked it not to, with nothing failing. It is now read by the views that animate, and a test
  refuses an `@Environment` declaration that is not inside a View.
- **The published control service UUID was wrong.** The repository stated
  `0000799a-d102-11e1-9b23-00025b00a5a5`; the earbuds' own SDP record and the vendor app's raw
  string pool both say `0000079a-…`. The byte form the app opens the channel with was always
  correct, so nothing failed — only the one digit that got published. The service's recorded name
  was wrong for the same reason (`enco link` is what the device reports; the old value came from a
  template in the ingest tool, not from hardware). See `EVIDENCE.md` and D13.

### Added

- **`EVIDENCE.md`**, the ledger every protocol fact is stated from: one row per fact, a confidence
  of measured / inferred / unconfirmed, and a citation to a byte offset, a class and method, or a
  frame, so anyone with the same file and hash can re-check it.
- **`Tools/dex-strings.py`**, which reads a DEX string table directly with file offsets, because a
  decompiler is lossy and has now hidden a literal here twice.
- **The earbuds' SDP record as read** (`capture/sdp-oneplus-buds-4-2026-10-19.txt`), which is where
  channel 29 (`WATCH`) first appears — advertised by hardware this project supports and described
  nowhere in it.

### Verified

- 182 protocol checks (the self-check), 28 SF Symbol names, 25 recorded frames from one model,
  and 59 tests.

## [0.1.1] — 2026-10-19

### Fixed

- **The site's FAQ markup now quotes the page.** Every page carried `FAQPage` structured data that
  disagreed with the FAQ a visitor could read — the same subjects in different words — and the
  supported-models page marked up three questions with no visible FAQ at all. Markup a reader cannot
  see is the exact overclaim this project exists to avoid, and it collected nothing in return: the
  rich result it was written for was retired in 2023. The markup is now generated from the visible
  FAQ by `Tools/faq-jsonld.py`, so the two cannot separate. Where the marked-up copy held the fuller
  answer, that answer moved onto the page: the FAQ gained the Audio MIDI Setup question, a longer
  emulator answer and the app's own wording for the case battery. See DECISIONS D9.
- **The first launch no longer claims the registry is missing.** With nothing paired, the window
  drew the "no capability registry" card — which describes a broken install — for the ordinary state
  of having no earbuds yet. The two are now different cards, and the `away` drawing that caught it
  is checked into the repository.
- **`--version` reads the version instead of repeating it.** It asks the bundle, which `swift run`
  does not have, so it falls back to one literal that `DocumentationTests` holds equal to the plist,
  the README and the site.

### Added

- **Documentation tests**, so the prose is checked rather than trusted: the `--selfcheck` count in
  this changelog and the README against the checks that actually run, the version the site
  advertises against the bundle, every internal link and sitemap entry against the files that ship,
  the home page's feature table against the registry's write paths, and "one model measured end to
  end" against the number of measured profiles. The site's own links and its absence of a made-up
  rating are checked too.
- **`--render` and `--compare`**, which draw the app's own window off-screen and compare it with the
  drawings in the repository. The picture on the website is now one of those files — the real
  `DeviceWindow` over the real `AppModel`, driven by the recording in the corpus, with the recording
  named in its own footer — so a layout that breaks fails `./build.sh` instead of shipping, and the
  image a visitor sees is an image that passed. See DECISIONS D10.

## [0.1.0] — 2026-10-18

First build anyone can run.

### Added

- **The app**, for macOS 26+ on Apple silicon: a window and a menu-bar item with the current noise
  mode and per-bud battery.
- **Noise control** on the measured model — Off, Noise Cancellation at High / Moderate / Low / Auto,
  Transparency and Adaptive — switched from the window or the menu bar.
- **Equalizer presets**, including the earbuds' own custom slot when one is already saved on them.
- **BassWave**, with the usable range read from the device rather than assumed (`−5…+5` on the
  measured model).
- **Touch gesture remapping**, limited to the actions the hardware has been observed to store.
- **Readings**: per-bud battery, wear state, active codec, the firmware string verbatim, and the
  multi-connect device list.
- **A capability registry** (`devices/*.json`). A model nobody has catalogued connects, reads what
  the earbuds report, and gets no write path at all.
- **A command line on the same binary**: `--selfcheck` (182 protocol checks), `--profiles`,
  `--devices`, `--replay <capture>`, `--version`.
- **Frame tracing** (`BUDSDESK_TRACE=1`) and `Tools/trace-to-capture.py`, so the next capture can be
  taken by this app rather than by its predecessor.
- **The protocol as prose and as data**: `protocol/PROTOCOL.md` and `protocol/spec.yaml`, each claim
  carrying an evidence level and a citation.
- **The website** (`docs/`), and this repository's own icon and disk-image art, generated by code.

### Fixed

- **`ancLevel` survived a switch out of noise cancellation.** A level means "how hard cancellation
  is working", so while the earbuds are transparent or adapting there is no honest value for it. A
  replay of the corpus showed mode `Adaptive` still displaying the level `Auto` from three frames
  earlier. A `.noiseMode` update that is not cancellation now clears the level.
- **The icon mark was drawn one icon-inset down and to the right** — 100 points at 1024 — because it
  was positioned with canvas coordinates inside a content-box coordinate space. Found by measuring
  the pixels of the rendered tile rather than by looking at it.

### Not included, on purpose

- **Firmware updates.** The update channel is never opened. Permanently out of scope; see
  `SCOPE.md` §4.
- **The charging case's battery.** It is never reported on this channel. The app says so rather than
  drawing an empty cell.
- **Find my earbuds.** The acknowledgement is byte-identical whether or not a tone plays, so nothing
  on this side can confirm it worked. See `DECISIONS.md` D5.
- **Switching the active multi-connect device.** The list is readable; writing it has not been
  observed, so no control is drawn.
- **A prompt-volume slider.** The getter's id was observed on hardware in an earlier experiment, but
  no request, decoder or control for it exists in this code.

### Model support

| Model | State |
|---|---|
| OnePlus Buds 4 | Measured end to end; every control above writes |
| Other OPPO / OnePlus / realme models advertising the control service | Connect and read; no write path |

[0.1.0]: https://github.com/shashank99928/BudsDesk/releases/tag/v0.1.0
