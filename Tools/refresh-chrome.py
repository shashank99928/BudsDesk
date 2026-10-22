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

# The window as it looks on a model nobody has recorded: every control drawn disabled with the
# reason on the card, and the readings as they arrive — which, for a model with no recording
# here, is as they have not arrived yet.
#
# The words are the app's own (`Sources/BudsDeskMac/Controls.swift`): the battery subtitle for
# a unit that has not reported, the noise subtitle for a mode that has not been reported, the
# note the app prints on a card whose capability has no write path, and the provenance footer's
# "Verified write paths: none". Nothing here is written for the page.
READ_ONLY_WINDOW = """<figure class="shot">
        <div class="window" data-ui>
          <div class="window-head">
            <div>
              <p class="window-title">{model}</p>
              <p class="window-sub">Connected.</p>
            </div>
            <button class="window-ghost" type="button">Disconnect</button>
          </div>

          <div class="window-scroll">
            <div class="wcard">
              <h3 class="wcard-title">Battery</h3>
              <p class="wcard-sub">The buds have not reported a charge yet.</p>
              <div class="wcells">
                <div class="wcell">
                  <span class="wcell-label">Left</span>
                  <span class="wcell-value is-quiet">&mdash;</span>
                  <span class="wcell-foot">unknown</span>
                </div>
                <div class="wcell">
                  <span class="wcell-label">Right</span>
                  <span class="wcell-value is-quiet">&mdash;</span>
                  <span class="wcell-foot">unknown</span>
                </div>
                <div class="wcell">
                  <span class="wcell-label">Case</span>
                  <span class="wcell-value is-quiet">&mdash;</span>
                  <span class="wcell-foot">unknown</span>
                </div>
              </div>
            </div>

            <div class="wcard">
              <h3 class="wcard-title">Noise control</h3>
              <p class="wcard-sub">The mode has not been reported yet. It is polled rather than
              pushed: the notification that carries it is lossy on this hardware.</p>
              <div class="wpills">
                <span class="wpill is-disabled">Off</span>
                <span class="wpill is-disabled">Noise cancellation<span class="wpill-detail">Cancellation at the last level used</span></span>
                <span class="wpill is-disabled">Transparency</span>
                <span class="wpill is-disabled">Adaptive</span>
              </div>
              <p class="wcard-label">Cancellation level</p>
              <div class="wpills">
                <span class="wpill is-disabled">High</span>
                <span class="wpill is-disabled">Moderate</span>
                <span class="wpill is-disabled">Low</span>
                <span class="wpill is-disabled">Auto</span>
              </div>
              <p class="wcard-note">This model has no measured write path for noise control, so the
              reported mode is shown and cannot be changed here.</p>
            </div>

            <div class="wcard">
              <h3 class="wcard-title">Equalizer</h3>
              <p class="wcard-sub">The preset has not been reported yet.</p>
              <div class="wpills">
                <span class="wpill is-disabled">Balanced</span>
                <span class="wpill is-disabled">Clear Vocals</span>
                <span class="wpill is-disabled">Bass</span>
                <span class="wpill is-disabled">Custom</span>
              </div>
              <p class="wcard-note">This model has no measured write path for the equalizer.</p>
            </div>
          </div>

          <div class="wfoot">
            <p>Profile generic-family &middot; Uncatalogued device &middot; OPPO / OnePlus / realme</p>
            <p>Verified write paths: none. Firmware updates are out of scope permanently and their
            channel is never opened.</p>
          </div>
        </div>
        <figcaption>
          The app's own window, rebuilt in the page. This is what it looks like on {brand}: the
          earbuds connect and everything they report is shown, and every control is drawn
          disabled with the reason on the card, because {yet}. The window's own foot says so in
          one line &mdash; <strong>Verified write paths: none</strong> &mdash; and the measured
          model, where the same controls do write, is
          <a href="/BudsDesk/oneplus-buds-4.html">the OnePlus Buds 4</a>.
        </figcaption>
      </figure>"""

# The pages that carry the read-only window: the name in its title bar, and how the caption
# names the kind of model it is showing.
READ_ONLY_PAGES = {
    "oppo-buds-on-mac.html": ("OPPO Enco", "an Enco model", "no Enco model has been recorded here"),
    "realme-buds-on-mac.html": ("realme Buds", "a realme model",
                                 "no realme model has been recorded here"),
    "index.html": ("Uncatalogued device", "a model this project has not recorded",
                    "no such model has been recorded here"),
}


def header_for(page: str) -> str:
    links = []
    for target, label in NAV_LINKS:
        current = ' aria-current="page"' if target == page else ""
        links.append(f'      <a href="/BudsDesk/{target}"{current}>{label}</a>')
    return HEADER.format(brand=BRAND, links="\n".join(links), download=DOWNLOAD)


def main() -> None:
    for path in sorted(SITE.glob("*.html")):
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"<header class=\"site\">.*?</header>",
                      lambda _: header_for(path.name), text, flags=re.S)
        text = re.sub(r"<footer class=\"site\">.*?</footer>",
                      lambda _: FOOTER.format(brand=BRAND), text, flags=re.S)

        # The read-only window, where a page carries one.
        if path.name in READ_ONLY_PAGES:
            model, brand, yet = READ_ONLY_PAGES[path.name]
            window = READ_ONLY_WINDOW.format(model=model, brand=brand, yet=yet)
            text = re.sub(r"<!-- BEGIN read-only window -->.*?<!-- END read-only window -->",
                          lambda _: "<!-- BEGIN read-only window -->\n" + window
                          + "\n      <!-- END read-only window -->", text, flags=re.S)

        path.write_text(text, encoding="utf-8")
        print(f"{path.name}: the bar and the footer rewritten")


if __name__ == "__main__":
    main()
