"""Write a rendered frame into the GitHub step summary as Markdown.

Annotations are capped in both count and length, so the base64 chunks were
being silently dropped. The step summary is a Markdown file with no practical
limit and is retrievable through the jobs API, which makes it the only channel
that reliably carries an image out of a runner.
"""
import base64
import io
import sys


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
