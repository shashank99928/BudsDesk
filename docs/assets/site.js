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
})();
