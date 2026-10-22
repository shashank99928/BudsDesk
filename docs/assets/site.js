/* BudsDesk site script.
 *
 * Two jobs, both of which the page can do without:
 *
 *  1. The entrance. Each part of a section rises into place once, as the section arrives.
 *     The elements are only hidden when the document has been marked `js`, which the page
 *     does in a script in the head, so a blocked script leaves the page exactly as it is
 *     rather than as a blank one.
 *  2. The frame reader. The frames in "every byte was seen first" are all in the page as
 *     markup; this only shows one at a time. Without it, every frame is on the page and
 *     the buttons are not.
 */

(function () {
    "use strict";

    // The page's head marks the document so the entrance can hide the parts it is about to
    // animate. This marks it again, once the script that does the animating is running: if
    // that script never arrives, the head's timer takes the mark back off and the page is
    // simply a page.
    document.documentElement.classList.add("motion");

    var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    // ---- The bar and the appearance -----------------------------------------
    //
    // Light is the default whatever the system says; dark is used only when the reader picks
    // it. The head applies a saved choice before the first paint; this only draws the switch
    // and records a new one. The switch is added here rather than written into every page's
    // bar, so the bar stays identical everywhere.

    var root = document.documentElement;
    var header = document.querySelector("header.site");

    function isDark() {
        return root.dataset.theme === "dark";
    }

    function paint(button) {
        button.setAttribute("aria-pressed", isDark() ? "true" : "false");
    }

    if (header) {
        var download = header.querySelector(".nav-download");
        if (download) {
            var toggle = document.createElement("button");
            toggle.type = "button";
            toggle.className = "theme-toggle";
            toggle.setAttribute("aria-label", "Dark appearance");
            toggle.innerHTML =
                '<svg class="icon-moon" viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>' +
                '<svg class="icon-sun" viewBox="0 0 24 24" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></svg>';

            toggle.addEventListener("click", function () {
                var next = isDark() ? "light" : "dark";
                root.dataset.theme = next;
                try { localStorage.setItem("budsdesk-theme", next); } catch (error) { }
                paint(toggle);
            });

            download.parentNode.insertBefore(toggle, download);
            paint(toggle);
        }

        // The bar gets its hairline only once the page has moved under it.
        var onScroll = function () {
            header.classList.toggle("is-scrolled", window.scrollY > 8);
        };
        window.addEventListener("scroll", onScroll, { passive: true });
        onScroll();
    }

    // ---- The entrance -------------------------------------------------------

    var parts = [].slice.call(document.querySelectorAll("[data-reveal]"));

    function show(part) {
        part.classList.add("is-in");
    }

    if (!parts.length) {
        return;
    }

    if (reduced || !("IntersectionObserver" in window)) {
        parts.forEach(show);
        return;
    }

    var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
            if (!entry.isIntersecting) { return; }
            show(entry.target);
            observer.unobserve(entry.target);
        });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.05 });

    parts.forEach(function (part, index) {
        // A short stagger between the parts of one section, so the section arrives in
        // pieces rather than all at once.
        part.style.transitionDelay = (index % 4) * 70 + "ms";
        observer.observe(part);
    });

    // Anything already on screen when the page loads is shown at once, without waiting
    // for a scroll.
    window.addEventListener("load", function () {
        parts.forEach(function (part) {
            var box = part.getBoundingClientRect();
            if (box.top < window.innerHeight && box.bottom > 0) { show(part); }
        });
    });

    // Printing the page is not scrolling it, so nothing would ever arrive.
    window.addEventListener("beforeprint", function () {
        parts.forEach(show);
    });

    // ---- The frame reader ---------------------------------------------------

    var buttons = [].slice.call(document.querySelectorAll(".wire-item"));
    var frames = [].slice.call(document.querySelectorAll(".wire-frame"));

    if (!buttons.length || !frames.length) {
        return;
    }

    function select(name) {
        buttons.forEach(function (button) {
            button.setAttribute("aria-selected", button.dataset.frame === name ? "true" : "false");
        });
        frames.forEach(function (frame) {
            frame.classList.toggle("is-active", frame.dataset.frame === name);
        });
    }

    buttons.forEach(function (button) {
        button.addEventListener("click", function () {
            select(button.dataset.frame);
        });
    });

    // ---- The window -------------------------------------------------------
    //
    // The noise control in the window, pressed. The rule it follows is the app's own: a write
    // is not applied when it is sent, it is applied when the earbuds read it back. So the
    // control goes pending, and only the answer settles it — and the answer is a frame from
    // the capture, not a picture of one.

    var frames = {};
    var frameData = document.getElementById("budsdesk-frames");
    if (frameData) {
        try {
            frames = JSON.parse(frameData.textContent);
        } catch (error) {
            frames = {};
        }
    }

    var card = document.querySelector("[data-card='noise']");
    var log = document.querySelector("[data-window-log]");
    if (!card || !log || !Object.keys(frames).length) {
        return;
    }

    var modeLabel = {
        off: "Off",
        noiseCancellation: "Noise cancellation",
        transparency: "Transparency",
        adaptive: "Adaptive"
    };
    var levelLabel = { high: "High", moderate: "Moderate", low: "Low", auto: "Auto" };

    function mark(pills, chosen) {
        pills.forEach(function (pill) {
            pill.setAttribute("aria-pressed", chosen(pill) ? "true" : "false");
        });
    }

    function press(pill, mode, level, frameName) {
        var frame = frames[frameName];

        // The write is on the wire and the earbuds have not answered yet: the control says so
        // and nothing else moves.
        card.querySelectorAll(".wpill").forEach(function (other) {
            other.classList.remove("is-pending");
        });
        pill.classList.add("is-pending");
        log.innerHTML = "<b>write sent</b> &mdash; waiting for the earbuds to read it back";

        window.setTimeout(function () {
            pill.classList.remove("is-pending");

            mark(card.querySelectorAll("[data-mode]"), function (other) {
                return other.dataset.mode === mode;
            });
            mark(card.querySelectorAll("[data-level]"), function (other) {
                return mode === "noiseCancellation" && other.dataset.level === level;
            });

            var subtitle = card.querySelector("[data-window-mode]");
            if (subtitle) {
                subtitle.textContent = mode === "noiseCancellation" && level
                    ? modeLabel[mode] + " · " + levelLabel[level]
                    : modeLabel[mode];
            }

            // The app's own log line, then the frame that answered.
            log.innerHTML = "<b>" + (level ? "level reported: " + levelLabel[level]
                                          : "mode reported: " + modeLabel[mode]) + "</b>"
                + (frame ? "<code>" + frame.hex + "</code><i>" + frame.note + "</i>" : "");
        }, 700);
    }

    card.querySelectorAll("[data-mode]").forEach(function (pill) {
        pill.addEventListener("click", function () {
            var mode = pill.dataset.mode;
            if (mode === "noiseCancellation") {
                // The mask carries the mode and the level together, so choosing cancellation
                // without a level uses the one the earbuds last reported — here, the highest.
                press(pill, mode, "high", "anc-reply-nc-high");
                return;
            }
            press(pill, mode, null, pill.dataset.frame);
        });
    });

    card.querySelectorAll("[data-level]").forEach(function (pill) {
        pill.addEventListener("click", function () {
            var level = pill.dataset.level;
            press(pill, "noiseCancellation", level, pill.dataset.frame);
        });
    });
})();
