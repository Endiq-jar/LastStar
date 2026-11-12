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

    # Unused member variables and constants. A `var _cull_timer` left behind by a
    # deleted feature reads as live state to the next person, and this project has
    # now grown two of them (`_cull_timer`, `CULL_NEAR`) plus `_enabled` and the
    # retired `FX` preload. Declarations are one line; a whole-function grep is
    # what misses them.
    # Scope note: the reference count is taken over the WHOLE source corpus, not
    # the declaring file. Autoload fields on the `Game` singleton (water_level,
    # lake_center, touch_move...) are written in game_state.gd and read from four
    # other scripts, so a per-file count reports all of them as dead. Only a
    # declaration that appears exactly once across the entire project is
    # genuinely unreferenced.
    decl_sites = {}
    for f, text in corpus.items():
        for m in re.finditer(r"^(?:static var|var|const) ([_A-Za-z][A-Za-z0-9_]*)\s*(?::|:=|=)",
                             text, re.M):
            decl_sites.setdefault(m.group(1), []).append(f.as_posix())

    # Two ways a declaration is dead:
    #
    #   * it never appears again anywhere in the project; or
    #   * every other appearance ASSIGNS to it - it is write-only.
    #
    # The second form is what a reference count cannot see, and it is the form
    # this project actually shipped: `_mesh_instance` was declared, null-tested
    # and assigned inside a loop that only wanted the first tile, and nothing
    # ever read it back. Three occurrences, so a count said "alive".
    decl_re = re.compile(r"^\s*(?:static var|var|const) (\w+)")
    for name, sites in sorted(decl_sites.items()):
        occ = [m.start() for m in re.finditer(r"\b" + re.escape(name) + r"\b", joined)]
        reads = 0
        for i in occ:
            line_start = joined.rfind("\n", 0, i) + 1
            dm = decl_re.match(joined[line_start:i + len(name) + 20])
            # `dm.group(1) == name` matters: without it any line that merely
            # STARTS with `var` counted as a declaration of this name, so a
            # usage on a `var` line was skipped and every constant used once
            # per line reported as dead.
            if dm is not None and dm.group(1) == name:
                continue
            tail = joined[i + len(name):i + len(name) + 4].lstrip()
            # `name =`, `name +=`, `name[` (an index write or a read - count it
            # as a read to stay conservative) - only a bare assignment is skipped.
            if re.match(r"^(?:\+=|-=|\*=|/=|=)\s*[^=]", tail):
                continue
            reads += 1
        if reads == 0:
            why = "write-only" if len(occ) > len(sites) else "unreferenced"
            problems.append("UNUSED DECLARATION  %s  (%s, %s)" % (name, why, sites[0]))

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
