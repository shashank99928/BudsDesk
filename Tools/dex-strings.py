#!/usr/bin/env python3
"""Read a DEX file's string table directly, with the file offset of every string.

This exists because a decompiler is a lossy instrument. `jadx` rewrites bytecode into Java and
drops what it cannot attribute to a class; a literal that survives in the raw string pool can be
missing from the decompiled tree. The string pool is the artefact, so this reads the artefact.

Nothing here is vendor code: it is a ~80-line reader for the documented DEX container format
(header, `string_ids` table, ULEB128 length prefix, NUL-terminated MUTF-8 payload).

    python3 Tools/dex-strings.py <file.dex | file.apk> --grep RE [--grep RE ...]
    python3 Tools/dex-strings.py <file.apk> --uuid
    python3 Tools/dex-strings.py <file.apk> --count

Offsets are reported as `<entry>:<hex offset>` so a finding can be cited down to the byte and
re-checked by anyone with the same file and its sha256. Output is stable and sorted, so a ledger
entry can quote it verbatim.
"""
import argparse
import json
import re
import struct
import sys
import zipfile

UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def uleb128(buf, pos):
    """Return (value, next_pos) for a ULEB128 at pos."""
    result = 0
    shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


def dex_strings(buf):
    """Yield (offset, text) for every string in one DEX image."""
    if buf[:3] != b"dex":
        raise ValueError("not a DEX image (no dex magic)")
    string_ids_size, string_ids_off = struct.unpack_from("<II", buf, 0x38)
    for i in range(string_ids_size):
        data_off = struct.unpack_from("<I", buf, string_ids_off + i * 4)[0]
        _, text_off = uleb128(buf, data_off)
        end = buf.index(b"\x00", text_off)
        # DEX stores MUTF-8; for the ASCII we are looking for it is byte-identical to UTF-8, and
        # `replace` keeps a multi-byte entry from aborting the read.
        yield data_off, buf[text_off:end].decode("utf-8", "replace")


def images(path):
    """Yield (label, bytes) for a .dex file, or every classes*.dex inside an .apk."""
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            names = sorted(n for n in z.namelist() if n.endswith(".dex"))
            if not names:
                sys.exit(f"{path}: no .dex entries")
            for n in names:
                yield n, z.read(n)
    else:
        with open(path, "rb") as fh:
            yield path, fh.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("target", help="a .dex file or an .apk")
    ap.add_argument("--grep", action="append", default=[], help="regex; repeatable, OR-ed")
    ap.add_argument("--uuid", action="store_true", help="only UUID-shaped strings")
    ap.add_argument("--count", action="store_true", help="print only the number of strings")
    ap.add_argument("--limit", type=int, default=200, help="max matches per image (default 200)")
    args = ap.parse_args()

    patterns = [re.compile(p) for p in args.grep]
    total = 0
    printed = 0

    for label, buf in images(args.target):
        strings = list(dex_strings(buf))
        total += len(strings)
        if args.count:
            print(f"{label}: {len(strings)} strings")
            continue
        for off, text in strings:
            if args.uuid and not UUID_RE.fullmatch(text):
                continue
            if patterns and not any(p.search(text) for p in patterns):
                continue
            if printed >= args.limit:
                continue
            printed += 1
            print(f"{label}:0x{off:x}  {text}")

    if args.count:
        print(f"total: {total} strings")


if __name__ == "__main__":
    main()
