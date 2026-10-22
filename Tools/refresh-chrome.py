#!/usr/bin/env python3
"""One-off: put the new bar and the new footer on every page of the site.

The pages all carried the same header and the same footer, copied into each file, which is
the arrangement that drifts. They are rewritten here in one place, so the next change is
made once.

    Tools/refresh-chrome.py
"""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "docs"

BRAND = '<a class="brand" href="/BudsDesk/"><span class="mark" aria-hidden="true"></span>BudsDesk</a>'

NAV_LINKS = [
    ("oneplus-buds-on-mac.html", "OnePlus Buds"),
    ("oppo-buds-on-mac.html", "OPPO Enco"),
    ("realme-buds-on-mac.html", "realme Buds"),
    ("models.html", "Models"),
]

DOWNLOAD = ("https://github.com/shashank99928/BudsDesk/releases/latest/download/BudsDesk.dmg")

HEADER = """<header class="site">
  <div class="wrap">
    {brand}
    <nav class="site" aria-label="Main">
{links}
    </nav>
    <a class="nav-download" href="{download}">Download</a>
  </div>
</header>"""

FOOTER = """<footer class="site">
  <div class="wrap">
    <div class="footer-grid">
      <div class="footer-about">
        {brand}
        <p>The missing desktop app for OPPO, OnePlus and realme earbuds. Free, MIT licensed, and
        it never talks to the network.</p>
      </div>

      <nav aria-label="Models">
        <h2>Models</h2>
        <ul>
          <li><a href="/BudsDesk/oneplus-buds-on-mac.html">OnePlus Buds</a></li>
          <li><a href="/BudsDesk/oppo-buds-on-mac.html">OPPO Enco</a></li>
          <li><a href="/BudsDesk/realme-buds-on-mac.html">realme Buds</a></li>
          <li><a href="/BudsDesk/models.html">Every model</a></li>
          <li><a href="/BudsDesk/oneplus-buds-4.html">OnePlus Buds 4</a></li>
        </ul>
      </nav>

      <nav aria-label="Reading">
        <h2>Reading</h2>
        <ul>
          <li><a href="/BudsDesk/anc-eq-on-mac.html">ANC and EQ on Mac</a></li>
          <li><a href="/BudsDesk/heymelody-on-mac.html">HeyMelody on Mac</a></li>
        </ul>
      </nav>

      <nav aria-label="Project">
        <h2>Project</h2>
        <ul>
          <li><a href="https://github.com/shashank99928/BudsDesk">Source</a></li>
          <li><a href="https://github.com/shashank99928/BudsDesk/releases">Releases</a></li>
          <li><a href="https://github.com/shashank99928/BudsDesk/blob/main/protocol/PROTOCOL.md">Protocol notes</a></li>
          <li><a href="https://github.com/shashank99928/BudsDesk/issues">Issues</a></li>
        </ul>
      </nav>
    </div>

    <div class="footer-fine">
      <p>BudsDesk is not made by, endorsed by, or affiliated with OPPO, OnePlus, realme, BBK
      Electronics, or the publisher of the phone companion app. Product names appear only as
      factual device names. No vendor code, icon, font or other asset is redistributed.</p>
      <p>MIT licensed. Built by measuring hardware, not by guessing.</p>
    </div>
  </div>
</footer>"""


def header_for(page: str) -> str:
    links = []
    for target, label in NAV_LINKS:
        current = ' aria-current="page"' if target == page else ""
        links.append(f'      <a href="/BudsDesk/{target}"{current}>{label}</a>')
    return HEADER.format(brand=BRAND, links="\n".join(links), download=DOWNLOAD)


def main() -> None:
    for path in sorted(SITE.glob("*.html")):
        if path.name == "index.html":
            continue
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"<header class=\"site\">.*?</header>",
                      lambda _: header_for(path.name), text, flags=re.S)
        text = re.sub(r"<footer class=\"site\">.*?</footer>",
                      lambda _: FOOTER.format(brand=BRAND), text, flags=re.S)
        path.write_text(text, encoding="utf-8")
        print(f"{path.name}: the bar and the footer rewritten")


if __name__ == "__main__":
    main()
