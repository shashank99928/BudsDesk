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
