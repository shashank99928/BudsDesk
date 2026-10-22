#!/usr/bin/env python3
"""Build the site's "what the wire carries" block out of the capture, not by hand.

The site's frames are the project's own evidence: the bytes that came off a real OnePlus
Buds 4. Transcribing them into HTML by hand would put a second copy of the recording on the
page, and a second copy can drift from the first without anything failing. So the block is
generated from `captures/<id>/frames.hex`, the same file the Swift corpus is generated from
and the same file a test asserts the corpus agrees with.

The page keeps the block between two markers:

    <!-- BEGIN capture frames -->  ...  <!-- END capture frames -->

and this script rewrites what is between them. A frame the capture does not contain is an
error, not a silent omission, and so is a frame whose bytes in the page are not the bytes in
the file.

    Tools/capture-html.py            # rewrite in place
    Tools/capture-html.py --check    # exit 1 if the page is out of step, write nothing
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CAPTURE = ROOT / "captures" / "oneplus-buds-4-2026-10-17" / "frames.hex"
PAGE = ROOT / "docs" / "index.html"

BEGIN = "<!-- BEGIN capture frames -->"
END = "<!-- END capture frames -->"

# The frames the page shows, in the order it shows them. Each entry is a title and the
# frames it carries; a frame that carries a label says what kind of frame it is.
#
# Every frame in the capture came *from* the earbuds: the corpus keeps the received
# direction, so a write appears here as the acknowledgement the earbuds sent back and the
# readback that followed it. The labels say so rather than implying the page holds the
# frames BudsDesk sends.
ENTRIES: list[tuple[str, list[tuple[str, str]]]] = [
    ("Battery", [("battery-reply", "The battery getter, answered")]),
    ("Wear", [("wear-reply", "The wear getter, answered")]),
    ("Noise control", [("anc-reply-adaptive", "The noise getter, answered")]),
    ("Equalizer", [
        ("setack-eq", "A write, answered"),
        ("eq-reply-bass", "The preset, read back"),
    ]),
    ("BassWave", [
        ("setack-basswave", "A write, answered"),
        ("basswave-reply-2", "The level, read back"),
    ]),
    ("Touch gestures", [("touch-reply", "The gesture table, answered")]),
    ("Firmware", [("firmware-reply", "The version string, answered")]),
    ("Multi-connect", [("multiconnect-reply", "The device list, answered")]),
]

FRAME = re.compile(r"^(?P<name>[a-z0-9-]+)\s*=\s*(?P<hex>[0-9a-f ]+)$")

# The frames the interactive window quotes, one per control it draws. The window shows the
# bytes the earbuds sent back, so every one of these has to be a frame the capture holds:
# a control that showed a frame nobody recorded would be the app inventing an answer.
WINDOW_FRAMES = [
    "anc-reply-off",
    "anc-reply-nc-high",
    "anc-reply-nc-moderate",
    "anc-reply-nc-low",
    "anc-reply-nc-auto",
    "anc-reply-transparency",
    "anc-reply-adaptive",
    "eq-reply-balanced",
    "eq-reply-bass",
    "eq-push-balanced",
    "eq-push-bass",
    "basswave-reply-0",
    "basswave-reply-2",
]


def read_capture() -> dict[str, dict[str, str]]:
    """Every frame in the capture: its comment, and its bytes.

    A frame's comment is every `#` line above it, which is how the capture file itself is
    written: a note can run over several lines and belongs to the frame below it.
    """
    frames: dict[str, dict[str, str]] = {}
    comment: list[str] = []
    for line in CAPTURE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            comment.append(stripped.lstrip("#").strip())
            continue
        match = FRAME.match(stripped)
        if match is None:
            raise SystemExit(f"the capture has a line this tool cannot read: {stripped!r}")
        frames[match["name"]] = {
            "comment": re.sub(r"\s+", " ", " ".join(comment)).strip(),
            "hex": " ".join(match["hex"].split()),
        }
        comment = []
    return frames


def shorten(comment: str, limit: int = 120) -> str:
    """A comment that fits on a line: its first sentence, cut at a word."""
    first = comment.split(" -- ")[0].split(". ")[0].strip()
    if len(first) <= limit:
        return first
    return first[:limit].rsplit(" ", 1)[0] + "…"


def build(frames: dict[str, dict[str, str]]) -> str:
    """The block: a list of frames on one side, the selected frame on the other."""
    lines: list[str] = []
    lines.append('<ol class="wire-list">')
    for index, (title, carried) in enumerate(ENTRIES):
        selected = "true" if index == 0 else "false"
        name = carried[0][0]
        lines.append(
            f'      <li><button class="wire-item" type="button" data-frame="{name}"'
            f' data-reveal aria-selected="{selected}">{title}'
            f' <span>{name}</span></button></li>')
    lines.append("    </ol>")
    lines.append('    <div class="wire-detail">')
    for index, (title, carried) in enumerate(ENTRIES):
        active = " is-active" if index == 0 else ""
        name = carried[0][0]
        lines.append(f'      <div class="wire-frame{active}" data-frame="{name}">')
        lines.append(f"        <h3>{title}</h3>")
        for frame_name, label in carried:
            frame = frames.get(frame_name)
            if frame is None:
                raise SystemExit(
                    f"the capture has no frame named `{frame_name}`; the page cannot show a frame "
                    "that was not recorded")
            lines.append(f'        <p class="wire-kind">{label}</p>')
            lines.append(f"        <pre>{frame['hex']}</pre>")
            lines.append(f"        <p class=\"wire-note\">{shorten(frame['comment'])}</p>")
        lines.append("      </div>")
    lines.append("    </div>")
    lines.append("    <script type=\"application/json\" id=\"budsdesk-frames\">")
    quoted = {}
    for name in WINDOW_FRAMES:
        frame = frames.get(name)
        if frame is None:
            raise SystemExit(
                f"the capture has no frame named `{name}`; the window cannot show a frame that "
                "was not recorded")
        quoted[name] = {"hex": frame["hex"], "note": shorten(frame["comment"])}
    lines.append(json.dumps(quoted, indent=2, sort_keys=True))
    lines.append("    </script>")
    return "\n".join(lines)


def main() -> int:
    check = "--check" in sys.argv[1:]
    frames = read_capture()
    block = build(frames)

    page = PAGE.read_text(encoding="utf-8")
    if BEGIN not in page or END not in page:
        print(f"{PAGE.name}: no capture markers; nothing to do", file=sys.stderr)
        return 1

    head, rest = page.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    rebuilt = f"{head}{BEGIN}\n{block}\n{END}{tail}"

    if rebuilt == page:
        print(f"{PAGE.relative_to(ROOT)}: the capture block is in step")
        return 0
    if check:
        print(f"{PAGE.relative_to(ROOT)}: the capture block is out of step; "
              "run Tools/capture-html.py", file=sys.stderr)
        return 1
    PAGE.write_text(rebuilt, encoding="utf-8")
    print(f"{PAGE.relative_to(ROOT)}: the capture block rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
