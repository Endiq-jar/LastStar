"""Print a small JPEG of a screenshot as base64, for embedding in CI logs.

Artifacts are stored on blob storage that some environments cannot reach, and
step logs are not always fetchable either. A single base64 line survives
everywhere, so the rendered frame can be inspected from the build output alone.
"""
import base64
import io
import sys


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    path = sys.argv[1]
    try:
        from PIL import Image
    except Exception:
        print("SHOT_ERROR: Pillow is unavailable in this runner")
        return 0
    try:
        im = Image.open(path).convert("RGB")
    except Exception as exc:  # noqa: BLE001 - report and carry on
        print("SHOT_ERROR: %s" % exc)
        return 0
    im.thumbnail((360, 360))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=58)
    raw = buf.getvalue()
    print("SHOT_SIZE: %dx%d %d bytes jpeg" % (im.width, im.height, len(raw)))
    print("SHOT_B64:" + base64.b64encode(raw).decode())
    return 0


if __name__ == "__main__":
    sys.exit(main())
