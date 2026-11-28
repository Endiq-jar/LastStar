#!/usr/bin/env python3
"""Attempt the official public Sketchfab download; stage it, never auto-import it.

Sketchfab may require a signed-in download or API authorization. This script
intentionally does not collect credentials or scrape/rehost the model. The
sandbox may also block connections to Sketchfab. An unsuccessful run leaves no
asset installed in the game.
"""
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

MODEL = "d83c3f837bae4c9aa52fafc476500386"
API = f"https://api.sketchfab.com/v3/models/{MODEL}/download"
ROOT = Path(__file__).resolve().parent.parent
STAGING = ROOT / ".cache" / "vintage-room"
MAX_BYTES = 300 * 1024 * 1024


def main() -> int:
    try:
        request = Request(API, headers={"Accept": "application/json", "User-Agent": "LastStar-asset-download/1.0"})
        with urlopen(request, timeout=30) as response:
            info = json.load(response)
        archive = info.get("glb") or info.get("gltf") or info.get("source")
        if not isinstance(archive, dict) or not isinstance(archive.get("url"), str):
            raise ValueError("Sketchfab did not provide a public archive URL")
        STAGING.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="vintage-room-", suffix=".part", dir=STAGING)
        try:
            with os.fdopen(fd, "wb") as output, urlopen(archive["url"], timeout=60) as response:
                size = 0
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    size += len(block)
                    if size > MAX_BYTES:
                        raise ValueError("archive exceeds 300 MiB staging limit")
                    output.write(block)
            target = STAGING / "sketchfab-download.archive"
            os.replace(name, target)
            print(f"Downloaded to {target}; inspect its contents, format and licence before integration.")
            return 0
        finally:
            if os.path.exists(name):
                os.unlink(name)
    except HTTPError as exc:
        print(f"Sketchfab returned HTTP {exc.code}; the download may require signing in.", file=sys.stderr)
    except (URLError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Could not download the Sketchfab asset: {exc}", file=sys.stderr)
    print("No model was installed. Download it through Sketchfab and provide the archive instead.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
