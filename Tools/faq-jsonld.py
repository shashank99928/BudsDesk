#!/usr/bin/env python3
"""Build each page's FAQPage structured data out of the FAQ the visitor can read.

The problem this exists to prevent: a page whose `<script type="application/ld+json">`
answers four questions that appear nowhere on the page. Google's structured-data policy
asks that marked-up content be visible to the reader, and the honest version of that rule
is stricter than passing a validator — the two should be the same words.

So the visible `<dl class="faq">` is the source. This reads it, and rewrites the
`mainEntity` array of the page's FAQPage block to quote it exactly: same questions in the
same order, same answers, verbatim. The `@id` and everything else in the block is left
alone. Run it after editing any FAQ, and `DocumentationTests` will hold the two together
either way.

    Tools/faq-jsonld.py            # rewrite in place
    Tools/faq-jsonld.py --check    # exit 1 if any page is out of step, write nothing

A page with no `FAQPage` block is left alone; a page whose block has no visible FAQ to
quote is an error, because that is the page cloaking a FAQ in markup.
"""

from __future__ import annotations

import html
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGES = sorted((ROOT / "docs").glob("*.html"))

FAQ_BLOCK = re.compile(r'<dl class="faq">(.*?)</dl>', re.S)
DT = re.compile(r"<dt>(.*?)</dt>", re.S)
DD = re.compile(r"<dd>(.*?)</dd>", re.S)

# The indent the existing blocks use, and the sentinel that says "this is a FAQPage".
MAIN_ENTITY = re.compile(
    r'("@type": "FAQPage",\n(?:\s*"@id": "[^"]*",\n)?\s*"mainEntity": \[)(.*?)(\n(\s*)\])',
    re.S,
)


def visible(html_fragment: str) -> str:
    """The reader's text: tags gone, entities decoded, runs of space collapsed.

    Collapsing is what lets the answer wrap in the HTML and sit on one line in JSON.
    """
    text = re.sub(r"<[^>]+>", "", html_fragment)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def questions(page: str) -> list[tuple[str, str]]:
    block = FAQ_BLOCK.search(page)
    if block is None:
        return []
    names = [visible(m) for m in DT.findall(block.group(1))]
    answers = [visible(m) for m in DD.findall(block.group(1))]
    if len(names) != len(answers):
        raise SystemExit(
            f"the FAQ has {len(names)} questions and {len(answers)} answers; "
            "a <dt> without a <dd> is a question nobody answered")
    if not names:
        raise SystemExit("the FAQ is empty")
    return list(zip(names, answers))


def entries(pairs: list[tuple[str, str]]) -> str:
    blocks = []
    for name, answer in pairs:
        blocks.append(
            "        {\n"
            '          "@type": "Question",\n'
            f"          \"name\": {json.dumps(name, ensure_ascii=False)},\n"
            '          "acceptedAnswer": {\n'
            '            "@type": "Answer",\n'
            f"            \"text\": {json.dumps(answer, ensure_ascii=False)}\n"
            "          }\n"
            "        }"
        )
    return "\n" + ",\n".join(blocks)


def analyse(path: pathlib.Path, apply: bool) -> tuple[bool, str]:
    """Compare one page's markup against its FAQ, and rewrite it unless `apply` is false.

    Returns whether the page was out of step and a line to print about it.
    """
    page = path.read_text(encoding="utf-8")
    match = MAIN_ENTITY.search(page)
    if match is None:
        return False, "no FAQPage block"

    pairs = questions(page)
    if not pairs:
        raise SystemExit(
            f"the FAQPage block marks up questions with no visible FAQ. Either give the page "
            'the <dl class="faq"> a reader would see, or delete the block.')

    rebuilt = match.group(1) + entries(pairs) + match.group(3)
    if rebuilt == match.group(0):
        return False, f"{len(pairs)} questions, in step"
    if apply:
        path.write_text(page[:match.start()] + rebuilt + page[match.end():], encoding="utf-8")
    return True, f"{len(pairs)} questions, " + ("rewritten" if apply else "out of step")


def main() -> int:
    check = "--check" in sys.argv[1:]
    out_of_step = 0
    for page in PAGES:
        try:
            stale, note = analyse(page, apply=not check)
        except SystemExit as failure:
            print(f"{page.name}: {failure}", file=sys.stderr)
            return 1
        print(f"{'!' if stale else ' '} {page.relative_to(ROOT)}: {note}")
        out_of_step += 1 if stale else 0

    if check and out_of_step:
        print(f"\n{out_of_step} page(s) out of step; run Tools/faq-jsonld.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
