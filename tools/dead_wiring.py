#!/usr/bin/env python3
"""Find files and declarations that exist but are wired to nothing.

This exists because a whole class of bug kept surviving review: five textures
(trunk.png, leaf.png, wood.png, wood_striped.png, trunk_stripped.png) sat in
assets/environment/ for several rounds while every tree rendered as a flat vertex
colour, because a merge helper dropped UVs and nothing ever loaded them. Two
sprite atlases were then wired in as surface textures and turned solid geometry
black. None of that shows up in a diff or a compile - the files "exist" and the
code "works".

Checks the things a compiler cannot:
  * asset files that no script references
  * const preloads declared and never used
  * .tscn scenes nothing instantiates

Exit 1 if anything is found, so CI can fail on it.

Usage: python3 tools/dead_wiring.py [--quiet]
"""
import pathlib
import re
import sys

SCAN_DIRS = ["scripts", "tests", "tools", "scenes"]
SOURCE_SUFFIXES = {".gd", ".tscn", ".tres", ".cfg", ".godot", ".gdshader", ".gdshaderinc"}
ASSET_DIRS = ["assets", "textures"]

# Entry points and standalone sandboxes, not instanced by name.
SCENE_ALLOWLIST = {
    "scenes/world.tscn",
    "scenes/main_menu.tscn",
    "tests/compile_check.tscn",
    "tests/mesh_check.tscn",
    "tests/render_probe.tscn",
    "scenes/environment/vegetation_demo.tscn",
}


def main() -> int:
    quiet = "--quiet" in sys.argv
    srcs = []
    for d in SCAN_DIRS:
        p = pathlib.Path(d)
        if p.is_dir():
            srcs.extend(f for f in p.rglob("*")
                        if f.is_file() and f.suffix in SOURCE_SUFFIXES)

    corpus = {f: f.read_text(encoding="utf-8", errors="replace") for f in srcs}
    joined = "\n".join(corpus.values())
    problems = []

    # Assets nothing points at. Loaders spell paths by filename.
    for d in ASSET_DIRS:
        p = pathlib.Path(d)
        if not p.is_dir():
            continue
        for asset in sorted(p.rglob("*")):
            if asset.is_file() and asset.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}:
                if asset.name not in joined:
                    problems.append("UNREFERENCED ASSET  %s" % asset.as_posix())

    # const preloads that are declared and never mentioned again.
    for f, text in corpus.items():
        for m in re.finditer(r'^const (\w+) := (?:preload|load)\("([^"]+)"\)', text, re.M):
            name, path = m.group(1), m.group(2)
            if len(re.findall(r"\b" + re.escape(name) + r"\b", text)) <= 1:
                problems.append("DEAD PRELOAD        %s -> %s  (%s)" % (name, path, f.as_posix()))

    # Scenes nothing instantiates.
    for scene in sorted(pathlib.Path(".").rglob("*.tscn")):
        rel = scene.as_posix()
        if rel.startswith(".git/") or rel in SCENE_ALLOWLIST:
            continue
        others = "\n".join(t for g, t in corpus.items() if g.as_posix() != rel)
        if scene.name not in others:
            problems.append("ORPHANED SCENE      %s" % rel)

    # Public functions with no reference anywhere. Informational: some are called
    # by name through call(), signals or the engine.
    func_hits = []
    for f, text in corpus.items():
        for m in re.finditer(r"^func (\w+)\(", text, re.M):
            name = m.group(1)
            if name.startswith("_"):
                continue
            total = len(re.findall(r"\b" + re.escape(name) + r"\b", joined))
            defined = len(re.findall(r"^func " + re.escape(name) + r"\(", joined, re.M))
            if total - defined <= 0:
                func_hits.append("UNCALLED FUNCTION   %s()  (%s)" % (name, f.as_posix()))

    if func_hits and not quiet:
        print("--- informational: public functions with no reference ---")
        for h in func_hits:
            print("  " + h)
        print()

    if problems:
        print("dead wiring found:")
        for p in problems:
            print("  " + p)
        print("\n%d problem(s)." % len(problems))
        return 1

    print("dead wiring: none. %d sources, %d scenes checked." % (len(srcs), len(list(pathlib.Path(".").rglob("*.tscn")))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
