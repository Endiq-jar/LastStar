#!/usr/bin/env python3
"""Catch the class of bug `gdparse` misses: a variable removed from a block
while a use of it survives.

GDScript's parser is lazy about scope in a way gdtoolkit's parser does not
model, so `gdparse` happily accepts a file where `fire_light` was deleted but
still referenced on the next line. Godot rejects it at reload, and on CI that
shows up as a headless-boot failure long after lint passed.

This is deliberately narrow: for each function it collects `var x` / `const x`
/ `for x in` / parameter names, then reports any `x.something` or `x =` /
`x(...)` receiver that is not in that set and is not a known engine name, a
member declared at file scope, or a builtin. False positives are cheap to
review; a shipped parse error is not.
"""
import re
import sys

INHERITED = set("""
position rotation scale transform global_position global_rotation global_transform
global_scale basis quaternion visible name owner children get_parent get_node
get_tree is_inside_tree is_instance_valid queue_free add_child remove_child
size modulate text pressed disabled focus_mode mouse_filter theme_override
light_energy shadow_enabled omni_range light_color visible emission_enabled
albedo_color emission_energy_multiplier emission mesh material_override
multimesh cast_shadow instance_count set_instance_transform transform_format
velocity move_and_slide is_on_floor create_tween tween_property bind connect
body_entered body_exited area_entered button_down button_up gui_input timeout
pressed mouse_entered mouse_exited process_mode collision_layer collision_mask
monitoring monitorable paused time_scale y_sort_enabled z_index clip_children
call_deferred set_process set_physics_process has_method call emit
""".split())

BUILTIN = set("""
self super this null true false void int float bool String Vector2 Vector3
Vector4 Color Array Dictionary Node Node3D Node2D Object RefCounted Resource
Mesh ArrayMesh MeshInstance3D MultiMesh MultiMeshInstance3D Transform3D Basis
Quaternion AABB Rect2 Plane Callable Signal PackedVector3Array PackedInt32Array
PackedFloat32Array PackedStringArray PackedByteArray PackedVector2Array
RandomNumberGenerator SceneTree Input OS Engine Time Mathf PI TAU
""".split())


def _strip(line):
    """Remove trailing comments and string literals so prose never matches."""
    out = []
    i = 0
    quote = None
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(" ")
            i += 1
            continue
        if c == "#":
            break
        out.append(c)
        i += 1
    return "".join(out)


def scan(path):
    src = open(path, encoding="utf-8").read()
    raw = src.split("\n")
    lines = [_strip(l) for l in raw]
    if not any(l.strip() for l in lines):
        return []
    # File-scope declarations: `var x`, `const X`, `static var x`, `@onready var x`.
    file_scope = set()
    for l in lines:
        m = re.match(r"\s*(?:@\w+\s+)?(?:static\s+)?(?:var|const)\s+([A-Za-z_]\w*)", l)
        if m and not l.startswith("\t") and not l.startswith("    "):
            file_scope.add(m.group(1))
    # Also treat any indented var as file scope if it is outside a func; simpler:
    # collect every `var`/`const` anywhere as potentially in scope (reduces noise).
    for l in lines:
        m = re.match(r"\s*(?:@\w+\s+)?(?:static\s+)?(?:var|const)\s+([A-Za-z_]\w*)", l)
        if m:
            file_scope.add(m.group(1))
    # Signals are declared as `signal name(...)` and are referenced as objects.
    for l in lines:
        m = re.match(r"\s*signal\s+([A-Za-z_]\w*)", l)
        if m:
            file_scope.add(m.group(1))
    # Every declared function is callable as a value / connectable.
    for l in lines:
        m = re.match(r"\s*(?:static\s+)?func\s+([A-Za-z_]\w*)", l)
        if m:
            file_scope.add(m.group(1))

    problems = []
    func = None
    local = set()
    params = set()
    for i, l in enumerate(lines):
        # Signatures can span lines:
        #     func f(a: int,
        #            b: Array) -> void:
        # so join continuation lines until the parenthesis closes.
        sig = l
        if re.search(r"\bfunc\s+[A-Za-z_]\w*\(", l) and sig.count("(") > sig.count(")"):
            j = i + 1
            while j < len(lines) and sig.count("(") > sig.count(")"):
                sig += " " + lines[j]
                j += 1
        m = re.match(r"\s*(?:static\s+)?func\s+([A-Za-z_]\w*)\((.*?)\)", sig)
        if m:
            func = m.group(1)
            params = set()
            for p in m.group(2).split(","):
                p = p.strip()
                if not p:
                    continue
                pn = re.match(r"([A-Za-z_]\w*)", p)
                if pn:
                    params.add(pn.group(1))
            local = set()
            continue
        if re.match(r"^\s*func\s", l) or re.match(r"^func\s", l):
            continue
        # declarations
        for pat in (r"\bvar\s+([A-Za-z_]\w*)", r"\bconst\s+([A-Za-z_]\w*)",
                    r"\bfor\s+([A-Za-z_]\w*)\s+in\b"):
            for mm in re.finditer(pat, l):
                local.add(mm.group(1))
        # Bare identifiers used as call arguments: `f(ghost, 1.0)`. This is the
        # shape that actually caused the shipped bug - a removed variable passed
        # straight into tween_property / connect / bind, with no `.` on it.
        stripped = l.strip()
        if not stripped.startswith(("func ", "class ", "extends", "signal ")):
            for mm in re.finditer(r"[(,]\s*(_?[a-z]\w*)\s*[,)]", l):
                name = mm.group(1)
                if (name in BUILTIN or name in INHERITED or name in file_scope
                        or name in local or name in params):
                    continue
                if name in {"if", "elif", "else", "for", "while", "return", "and",
                            "or", "not", "in", "is", "await", "match", "when",
                            "true", "false", "null", "self"}:
                    continue
                problems.append((i + 1, name, l.strip()))
        # Assignment targets: `foo = ...` / `foo += ...` where foo is a bare
        # local name. This is how a deleted member variable usually survives -
        # the removal takes the declaration and leaves the write behind.
        am = re.match(r"\s*(_?[a-z]\w*)\s*(?:\+|-|\*|/)?=\s*[^=]", l)
        if am:
            aname = am.group(1)
            if not (aname in BUILTIN or aname in INHERITED or aname in file_scope
                    or aname in local or aname in params):
                problems.append((i + 1, aname, l.strip()))

        # receivers: `name.` where name is a bare identifier at statement level
        for mm in re.finditer(r"(?<![\w.\"])(_?[a-z]\w*)\s*\.\s*[A-Za-z_]", l):
            name = mm.group(1)
            if (name in BUILTIN or name in INHERITED or name in file_scope
                    or name in local or name in params):
                continue
            # skip keywords / common singletons
            if name in {"if", "elif", "else", "for", "while", "return", "and",
                        "or", "not", "in", "is", "await", "match", "when"}:
                continue
            problems.append((i + 1, name, l.strip()))
    return problems


def main():
    bad = 0
    for path in sys.argv[1:]:
        probs = scan(path)
        # Collapse duplicates of the same name in the same file.
        seen = set()
        for line_no, name, text in probs:
            key = (path, name)
            if key in seen:
                continue
            seen.add(key)
            print(f"{path}:{line_no}: '{name}' is used but not declared in scope")
            print(f"    {text}")
            bad += 1
    if bad:
        print(f"\n{bad} possible undeclared identifier(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
