#!/usr/bin/env python3
"""Cheap static checks on the Godot shader sources.

There is no shader compiler in this environment, so every mistake in a .gdshader
costs a full CI cycle to discover - and worse, Godot does not fail the run for a
shader that does not compile: it logs an error and draws the surface with a
default white material. That is how a meadow ended up pale lavender and got
diagnosed as an art problem.

These checks only cover the mistakes that have actually happened, which are the
subtle ones: shader source is GLSL, not GDScript, and it is easy to type GDScript
in it without noticing.

  * `:=` is GDScript's inferred declaration and is a syntax error in GLSL.
  * A GDScript-style `func` is a syntax error too.
  * Camera built-ins are fragment-stage only; using one in vertex() fails to
    compile on the Compatibility renderer.

Exit code 1 if anything is found, so it can gate locally as well as in CI.
"""

from __future__ import annotations

import pathlib
import re
import sys

SHADER_DIR = pathlib.Path("shaders")

# Built-ins that exist only in the fragment stage of a spatial shader.
FRAGMENT_ONLY = (
    "CAMERA_POSITION_WORLD",
    "MAIN_CAM_INV_VIEW_MATRIX",
    "VIEW",
)

problems: list[str] = []


def check(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    in_vertex = False
    depth = 0
    for number, line in enumerate(lines, start=1):
        code = line.split("//")[0]

        if ":=" in code:
            problems.append(
                f"{path}:{number}: ':=' is GDScript, not GLSL - use '=' with an "
                f"explicit type ({code.strip()})"
            )
        if re.search(r"^\s*func\s", code):
            problems.append(f"{path}:{number}: 'func' is GDScript, not GLSL")
        if re.search(r"\bvar\s+\w+\s*:", code):
            problems.append(f"{path}:{number}: 'var' is GDScript, not GLSL")

        if re.match(r"\s*void\s+vertex\s*\(", code):
            in_vertex = True
            depth = code.count("{") - code.count("}")
            continue
        if in_vertex:
            depth += code.count("{") - code.count("}")
            for builtin in FRAGMENT_ONLY:
                if builtin in code:
                    problems.append(
                        f"{path}:{number}: {builtin} is fragment-stage only and "
                        f"cannot be read in vertex() - pass it as a uniform"
                    )
            if depth <= 0:
                in_vertex = False


def main() -> int:
    if not SHADER_DIR.is_dir():
        print(f"no {SHADER_DIR}/ directory here")
        return 1
    shaders = sorted(SHADER_DIR.glob("*.gdshader"))
    for path in shaders:
        check(path)
    if problems:
        for p in problems:
            print(f"SHADER_FAIL: {p}")
        print(f"\n{len(problems)} problem(s) in {len(shaders)} shaders")
        return 1
    print(f"checked {len(shaders)} shaders, no problems")
    return 0


if __name__ == "__main__":
    sys.exit(main())
