#!/usr/bin/env python3
"""Turn a BudsDesk trace log into a capture directory.

    ./Tools/trace-to-capture.py budsdesk-trace.log \
        --id oneplus-buds-5-2026-11-02 \
        --model "OnePlus Buds 5" --vendor OnePlus --firmware "2,1,7,..." \
        [--unique] [--include-tx] [--dir captures]

This tool does the mechanical half of making a capture and refuses the interpretive half.

**What it does.** Copies the received frames out of the log without touching a byte, stamps each
with the time it arrived, and writes `captures/<id>/frames.hex` in the format
`Tools/freeze-captures.sh` parses. A byte is never retyped, which is the whole reason this exists
rather than a person copying hex out of a log by hand.

**What it does not do.** It does not name the frames and it does not guess provenance. An entry is
`rx-001` with a note saying when it arrived; naming it `battery-reply` is an act of interpretation,
because a frame is "battery" only because somebody set a battery control and watched what came
back. Likewise, the firmware string is a fact about a device that this tool cannot observe, so
`--firmware` is required and there is no default. A capture with an invented firmware string is
worse than no capture: every claim below it inherits the lie.

**What it checks.** That each received line's bytes parse as a frame whose two length fields agree.
A line that does not is reported and the run stops, because a fragment or a stray byte in a
recording is information and dropping it quietly is how a fixture stops being a record of what
happened.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

HEADER_RE = re.compile(r"^#\s*started\s+(?P<started>\S+)")
LINE_RE = re.compile(r"^(?P<dir>RX|TX)\s+(?P<ms>\d+)\s+(?P<hex>[0-9a-f ]+)$")


def die(message):
    sys.stderr.write("trace-to-capture: %s\n" % message)
    sys.exit(1)


def parse_frame(blob):
    """Return (ok, reason). Mirrors the codec's rule: both length fields must describe the bytes."""
    if len(blob) < 9:
        return False, "shorter than a header (%d bytes)" % len(blob)
    if blob[0] != 0xAA:
        return False, "does not start with 0xaa (found 0x%02x)" % blob[0]
    length = blob[1]
    if length & 0x80:
        return False, "multi-byte length varint, which no frame in the corpus uses"
    if 1 + 1 + length != len(blob):
        return False, ("len says %d, so the frame should be %d bytes, but it is %d"
                       % (length, 1 + 1 + length, len(blob)))
    payload_len = blob[7] | (blob[8] << 8)
    if payload_len != length - 7:
        return False, ("payloadLen says %d, len says %d (which implies %d)"
                       % (payload_len, length, length - 7))
    return True, None


def main():
    parser = argparse.ArgumentParser(add_help=True, description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", help="a BudsDesk trace log (BUDSDESK_TRACE=1)")
    parser.add_argument("--id", required=True, help="capture id; also the directory name")
    parser.add_argument("--model", required=True)
    parser.add_argument("--vendor", required=True)
    parser.add_argument("--firmware", required=True,
                        help="the firmware string exactly as the device reported it")
    parser.add_argument("--firmware-source", default="read from the device's own firmware reply",
                        help="how that string was obtained")
    parser.add_argument("--tool", default="BudsDesk with BUDSDESK_TRACE=1")
    parser.add_argument("--host", default=None,
                        help="defaults to this machine; pass it explicitly if you are not on the "
                             "machine that recorded the trace")
    parser.add_argument("--unique", action="store_true",
                        help="keep only the first occurrence of each distinct frame")
    parser.add_argument("--include-tx", action="store_true",
                        help="keep the app's own writes as well as the device's frames")
    parser.add_argument("--dir", default="captures")
    args = parser.parse_args()

    if not os.path.isfile(args.log):
        die("no such log: %s" % args.log)

    destination = os.path.join(args.dir, args.id)
    if os.path.exists(destination):
        die("%s already exists; a capture is never overwritten" % destination)

    started = None
    frames = []
    skipped_tx = 0
    malformed = []

    with open(args.log, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.rstrip("\n")
            if line.startswith("#"):
                header = HEADER_RE.match(line)
                if header and started is None:
                    started = header.group("started")
                continue
            if not line.strip():
                continue
            match = LINE_RE.match(line)
            if not match:
                die("%s:%d: not a header, a comment or an entry: %r" % (args.log, lineno, line))
            if match.group("dir") == "TX" and not args.include_tx:
                skipped_tx += 1
                continue
            blob = bytes(int(tok, 16) for tok in match.group("hex").split())
            ok, reason = parse_frame(blob)
            if not ok:
                malformed.append((lineno, match.group("dir"), reason, match.group("hex")))
                continue
            frames.append((match.group("dir"), int(match.group("ms")), blob))

    if malformed:
        for lineno, direction, reason, hexstr in malformed:
            sys.stderr.write("%s:%d: %s frame does not parse: %s\n    %s\n"
                             % (args.log, lineno, direction, reason, hexstr))
        die("%d line(s) did not parse; the log is a record, so fix the log rather than the tool"
            % len(malformed))

    if not frames:
        die("no received frames in %s%s"
            % (args.log, "" if args.include_tx else " (TX frames are skipped unless --include-tx)"))

    if args.unique:
        seen = set()
        deduped = []
        for direction, stamp, blob in frames:
            if blob in seen:
                continue
            seen.add(blob)
            deduped.append((direction, stamp, blob))
        frames = deduped

    host = args.host
    if host is None:
        try:
            release = subprocess.run(["sw_vers", "-productVersion"], capture_output=True,
                                     text=True, check=True).stdout.strip()
        except Exception:
            release = "unknown"
        machine = subprocess.run(["uname", "-m"], capture_output=True,
                                 text=True).stdout.strip()
        host = "macOS %s, %s, IOBluetooth RFCOMM" % (release, machine)

    os.makedirs(destination)
    frames_path = os.path.join(destination, "frames.hex")
    with open(frames_path, "w", encoding="utf-8") as handle:
        handle.write("# Received frames from a BudsDesk trace.\n")
        handle.write("#\n")
        handle.write("# Entries are named rx-NNN and carry the time they arrived. Rename each one\n")
        handle.write("# to what it is -- 'battery-reply', 'anc-reply-nc-high' -- once you know,\n")
        handle.write("# and say what was set before it arrived. A name is an interpretation and\n")
        handle.write("# this tool does not make them.\n")
        handle.write("\n")
        for index, (direction, stamp, blob) in enumerate(frames, 1):
            when = datetime.datetime.fromtimestamp(stamp / 1000).isoformat(timespec="milliseconds")
            hexstr = " ".join("%02x" % byte for byte in blob)
            handle.write("# %s at %s\n" % (direction, when))
            handle.write("rx-%03d = %s\n\n" % (index, hexstr))

    manifest = {
        "id": args.id,
        "date": (started or datetime.date.today().isoformat())[:10],
        "model": args.model,
        "vendor": args.vendor,
        "firmware": args.firmware,
        "firmwareSource": args.firmware_source,
        "service": {
            "name": "oppointeraction",
            "uuid": "0000799a-d102-11e1-9b23-00025b00a5a5",
            "rfcommChannel": None,   # not in a trace log; fill it in from the SDP record
        },
        "tool": args.tool,
        "host": host,
        "frames": len(frames),
        "notes": "Produced by Tools/trace-to-capture.py. Frames still carry generated names.",
    }

    manifest_path = os.path.join(destination, "capture.json")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print("wrote %s (%d frames%s)" % (frames_path, len(frames),
                                      ", deduplicated" if args.unique else ""))
    if skipped_tx:
        print("      skipped %d TX frame(s)" % skipped_tx)
    print("wrote %s" % manifest_path)
    print()
    print("still to do, and deliberately not done here:")
    print("  · set service.rfcommChannel in capture.json from the SDP record")
    print("  · rename the rx-NNN entries to what each frame actually is")
    if args.host is None:
        print("  · confirm host: it was taken from this machine (%s)" % host)
    print("  · then: ./Tools/freeze-captures.sh && swift test")


if __name__ == "__main__":
    main()
