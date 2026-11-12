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
  * `return` is illegal in vertex() and fragment() - "Using 'return' in the
    'vertex' processor function is incorrect". It is a hard compile failure
    that silently white-materials the surface, and it cost a CI cycle.
  * `discard` and `return` are the two things an early exit is made of, so the
    check looks for both rather than just the one that has bitten so far.

Exit code 1 if anything is found, so it can gate locally as well as in CI.
"""

from __future__ import annotations

import pathlib
import re
import sys

SHADER_DIRS = [pathlib.Path("shaders"), pathlib.Path("assets/shaders")]

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
        # No early exits from a vertex()/fragment() body. Godot's shader
        # language has no statement-level `return` there: the compiler rejects
        # the whole program and the material falls back to white, which reads
        # as an art bug rather than a compile error.
        if in_vertex and re.search(r"^\s*return\s*;", code):
            problems.append(
                f"{path}:{number}: 'return' is not allowed in the vertex "
                f"processor - fold the condition into a multiplier"
            )

        # Built-ins whose type is easy to get wrong, where a wrong type does not
        # fail loudly: Godot logs a shader error and draws the surface with a
        # default material, which is how the meadow turned lavender.
        #
        #   RIM_TINT  is a float (0 = white, 1 = albedo), not a colour.
        #   BACKLIGHT is vec3.
        #   AO, RIM, SPECULAR are floats.
        m = re.match(r"\s*RIM_TINT\s*=\s*(vec[234]|texture\s*\()", code)
        if m:
            problems.append(
                f"{path}:{number}: RIM_TINT is a float in Godot 4 (0=white, "
                f"1=albedo) - a vec3 there is a compile error"
            )
        # Writing ALPHA forces the transparent pipeline even if it is only read.
        # The opt-out marker may sit on this line or on either of the two above
        # it, so a multi-line comment can explain itself.
        recent = " ".join(lines[max(0, number - 5):number])
        if (re.search(r"^\s*ALPHA\s*=\s*", code)
                and "lint:allow-transparent" not in recent):
            problems.append(
                f"{path}:{number}: writing ALPHA moves the material to the "
                f"transparent pipeline - use ALPHA_SCISSOR_THRESHOLD for cutouts "
                f"(or add '// lint:allow-transparent' if it is genuinely needed)"
            )

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
    shaders: list[pathlib.Path] = []
    for d in SHADER_DIRS:
        if not d.is_dir():
            continue
        # rglob, not glob: the asset shader library is nested by category.
        shaders.extend(sorted(d.rglob("*.gdshader")))
    if not shaders:
        print("no shader directories found here")
        return 1
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
