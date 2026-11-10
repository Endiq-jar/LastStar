#!/usr/bin/env python3
"""Post-export sanity gate for the CI desktop builds.

Two failure modes this exists to catch, because both have happened and both are
invisible in the job log alone:

1. An export step "succeeds" but writes nothing (or a stub) because a preset was
   misconfigured. Godot exits 0 in some of those cases.
2. The 32-bit preset silently exports a 64-bit binary, so the artifact claims to
   ship x86 support that is not actually there.

Checking the PE header's machine field proves the architecture rather than
trusting the preset name.
"""

from __future__ import annotations

import struct
import sys

# PE header machine values we care about. See the PE/COFF spec.
MACHINES = {
    0x8664: "x86_64",
    0x014C: "i386",
    0xAA64: "arm64",
}

# (label, path, architecture we require)
EXPECTED = [
    ("linux x64", "build/linux/LastStar.x86_64", None),
    ("windows x64", "build/windows/LastStar.exe", "x86_64"),
    ("windows x32", "build/windows32/LastStar.exe", "i386"),
]


def pe_machine(path: str) -> str | None:
    """Return the PE architecture name, or None if this is not a PE file."""
    with open(path, "rb") as fh:
        head = fh.read(0x400)
        if head[:2] != b"MZ":
            return None
        offset = struct.unpack_from("<I", head, 0x3C)[0]
        fh.seek(offset)
        signature = fh.read(6)
    if signature[:4] != b"PE\0\0":
        return None
    return MACHINES.get(struct.unpack_from("<H", signature, 4)[0], "unknown")


def main() -> int:
    failures = []
    for label, path, want in EXPECTED:
        try:
            size = __import__("os").path.getsize(path)
        except OSError:
            failures.append("%s: missing %s" % (label, path))
            print("FAIL  %-12s %s does not exist" % (label, path))
            continue
        if size < 1_000_000:
            failures.append("%s: %s is only %d bytes" % (label, path, size))
            print("FAIL  %-12s %s suspiciously small (%d bytes)" % (label, path, size))
            continue
        got = pe_machine(path) if path.endswith(".exe") else "n/a"
        detail = ""
        if want:
            detail = "PE %s" % got
            if got != want:
                failures.append("%s: wanted %s, got %s" % (path, want, got))
                print("FAIL  %-12s %s is %s, wanted %s" % (label, path, got, want))
                continue
        print("OK    %-12s %s  %.1f MB  %s" % (label, path, size / 1e6, detail))

    if failures:
        print("\n%d export check(s) failed" % len(failures))
        return 1
    print("\nAll exports present and correctly targeted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
