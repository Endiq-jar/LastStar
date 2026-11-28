#!/usr/bin/env python3
"""Inventory glTF mesh primitives without modifying third-party assets.

Counts mesh definitions, not scene instances, animation, skinning or runtime
visibility. Non-indexed triangles use POSITION counts. Lines/strips and broken
assets are reported as unknown, not silently estimated.
"""
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def parse(path: Path) -> dict:
    if path.suffix.lower() == ".gltf":
        return json.loads(path.read_text(encoding="utf-8"))
    with path.open("rb") as stream:
        magic, version, _ = struct.unpack("<4sII", stream.read(12))
        if magic != b"glTF" or version != 2:
            raise ValueError("not a glTF 2 binary")
        length, kind = struct.unpack("<II", stream.read(8))
        if kind != 0x4E4F534A or length > 64 * 1024 * 1024:
            raise ValueError("missing JSON chunk")
        return json.loads(stream.read(length))


def counts(data: dict) -> tuple[int, int, bool]:
    triangles = vertices = 0
    unknown = False
    accessors = data.get("accessors", [])
    for mesh in data.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            position = primitive.get("attributes", {}).get("POSITION")
            if position is None:
                unknown = True
                continue
            vertex_count = int(accessors[position]["count"])
            vertices += vertex_count
            if primitive.get("mode", 4) != 4:
                unknown = True
                continue
            index = primitive.get("indices")
            triangles += int(accessors[index]["count"] if index is not None else vertex_count) // 3
    return triangles, vertices, unknown


def main() -> None:
    files = sorted(p for p in (ROOT / "assets").rglob("*") if p.suffix.lower() in (".gltf", ".glb"))
    print("Mesh definitions only; not runtime totals. Environment assets are included for reference.")
    for path in files:
        try:
            triangles, vertices, unknown = counts(parse(path))
            print(f"{path.relative_to(ROOT)}\t{triangles} triangles\t{vertices} vertices" + ("\tpartial" if unknown else ""))
        except (OSError, ValueError, KeyError, IndexError, struct.error, json.JSONDecodeError) as exc:
            print(f"{path.relative_to(ROOT)}\tunknown: {exc}")


if __name__ == "__main__":
    main()
