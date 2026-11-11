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
    im.thumbnail((420, 420))
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=62)
    raw = buf.getvalue()
    print("SHOT_SIZE: %dx%d %d bytes jpeg" % (im.width, im.height, len(raw)))
    # Annotations are truncated hard (~1000 chars), so emit the payload in
    # short numbered chunks that can be concatenated back together.
    payload = base64.b64encode(raw).decode()
    chunk = 600
    for i in range(0, len(payload), chunk):
        print("SHOT_PART:%03d:%s" % (i // chunk, payload[i:i + chunk]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
