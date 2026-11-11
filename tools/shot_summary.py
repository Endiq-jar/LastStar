"""Write a rendered frame into the GitHub step summary as Markdown.

Annotations are capped in both count and length, so the base64 chunks were
being silently dropped. The step summary is a Markdown file with no practical
limit and is retrievable through the jobs API, which makes it the only channel
that reliably carries an image out of a runner.
"""
import base64
import io
import sys


def measure_ground(im):
    """Replicate tests/render_probe.gd::_measure_ground_ratio.

    The probe's own number is only visible if the software-GL step actually
    ran; when apt fails to install Mesa that step degrades to a warning and the
    measurement disappears with no trace. Summarising here means the same frame
    always yields the same number regardless of which step survived.

    Returns (ratio, lit, dark, lit_at, dark_at) or None.
    """
    w, h = im.size
    px = im.load()
    step = max(1, w // 220)
    lit, dark = -1.0, 2.0
    lit_at = dark_at = None
    count = 0
    for y in range(int(h * 0.28), int(h * 0.82), step):
        for x in range(0, w, step):
            if 0.38 * w < x < 0.62 * w:
                continue
            r, g, b = px[x, y][:3]
            r, g, b = r / 255.0, g / 255.0, b / 255.0
            if g <= r + 0.04 or g <= b + 0.04:
                continue
            l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if l > lit:
                lit, lit_at = l, (x, y)
            if l < dark:
                dark, dark_at = l, (x, y)
            count += 1
    if count < 32 or dark <= 0.001 or lit <= 0.0:
        return None
    return (lit / dark, lit, dark, lit_at, dark_at)


def main(argv) -> int:
    try:
        from PIL import Image
    except Exception:
        print("Pillow unavailable - cannot embed screenshots")
        return 0

    print("\n## Rendered frame\n")
    found = False
    for path in argv[1:]:
        try:
            im = Image.open(path).convert("RGB")
        except Exception:
            print("- `%s`: missing\n" % path)
            continue
        found = True
        # Downscale so the base64 stays a sane size in the summary document.
        # Measure before thumbnailing, on the full-resolution frame.
        m = measure_ground(im)
        if m:
            ratio, lit, dark, lit_at, dark_at = m
            verdict = "OK" if 1.8 <= ratio <= 3.0 else (
                "HOLE" if ratio > 4.0 else "LOW-CONTRAST")
            print("**ground contrast** %.1fx (%s) - lit %.3f @%s, "
                  "dark %.3f @%s; target 1.8-3.0\n"
                  % (ratio, verdict, lit, lit_at, dark, dark_at))
        im.thumbnail((560, 560))
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=70)
        b64 = base64.b64encode(buf.getvalue()).decode()
        # A Markdown image with a data URI renders inline on GitHub.
        print("**%s** (%dx%d)\n" % (path.rsplit("/", 1)[-1], im.width, im.height))
        print("![frame](data:image/jpeg;base64,%s)\n" % b64)
        # Also emit a plain-text payload with explicit markers, so the bytes can
        # be recovered even if the inline image does not render.
        print("<details><summary>raw payload</summary>\n")
        for i in range(0, len(b64), 76):
            print(b64[i:i + 76])
        print("\n</details>\n")
    if not found:
        print("No screenshots were produced.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
