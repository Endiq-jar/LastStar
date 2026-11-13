#!/usr/bin/env python3
"""Check that every surface's shadow fill sits on the same scale.

Why this exists
---------------
The render probe reported "shadowed ground is reading as a hole" at a lit/dark
ratio of 7.8x against its own 1.8-3.0 target, and it was misdiagnosed for
several rounds as a terrain problem. It was not: the darkest pixels were grass
blades, and grass was filling shadows at `base * 0.10` while the terrain under
it filled at roughly `col * 2.06`. Two surfaces lit on scales twenty times
apart cannot agree about what shadow looks like, no matter how either one is
tuned in isolation.

The reason this took so long is that the only check which could see the problem
was a GPU screenshot, and that check needs a framebuffer - which needs Mesa on
the runner, which fails intermittently. When it fails, nothing is measured and
nothing looks wrong.

This check needs no GPU. It reads the EMISSION expression straight out of each
shader, evaluates it over a sweep of plausible albedo values, and asserts the
surfaces land in the same value range. It is arithmetic, so it is exact and it
cannot be skipped by a mirror timeout.

It does not replace the pixel probe - only a real frame proves the picture is
right - but it does catch the specific class of bug that the pixel probe was
being used to find, and it catches it deterministically.

Usage:  python3 tools/fill_check.py [--verbose]
Exit:   0 = fills are consistent, 1 = a surface is out of band.
"""
import math
import re
import sys

# Surfaces that must agree with each other about shadow. Each entry is a path
# plus the sweep variable that stands in for "albedo".
SURFACES = [
    ("shaders/terrain/terrain_anime.gdshader", ["col", "patch"]),
    ("shaders/terrain/grass_card.gdshader", ["base", "col", "t", "v_tint"]),
]

# Any two surfaces' fills must stay within this factor of each other. A factor
# of 2 is invisible in a stylised frame; the bug that motivated this check was
# a factor of 20.
MAX_SPREAD = 2.0

# Absolute band every ground fill must land in, in linear luminance.
#
# A ratio-only test is not enough, and this is not hypothetical: scaling grass
# fill by 1.95 to match the terrain's 2.06 equalised the *ratio* (7.8x -> 4.9x)
# while pushing the sunlit meadow to rgb(235,255,197) with green clipped at 255.
# A fill can be consistent with its neighbour and still be wrong in absolute
# terms - too dark reads as a hole, too bright reads as a glowing lawn.
# Sunlit ground fill should sit clearly below the key light; shadow fill should
# sit clearly above black.
FILL_MIN = 0.03
FILL_MAX = 0.55

# Albedo range swept. Stylised painted ground and grass both live here.
ALBEDOS = [0.05, 0.08, 0.12, 0.16, 0.20, 0.26, 0.32, 0.40, 0.50]


def luminance(rgb):
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]


class Vec3(list):
    def __init__(self, *a):
        if len(a) == 1 and isinstance(a[0], (list, tuple, Vec3)):
            super().__init__([float(v) for v in a[0]])
        elif len(a) == 1:
            super().__init__([float(a[0])] * 3)
        else:
            super().__init__([float(v) for v in a[:3]])

    def _op(self, o, f):
        if isinstance(o, (int, float)):
            return Vec3([f(a, o) for a in self])
        return Vec3([f(a, b) for a, b in zip(self, o)])

    def __add__(self, o):
        return self._op(o, lambda a, b: a + b)

    def __radd__(self, o):
        return self.__add__(o)

    def __sub__(self, o):
        return self._op(o, lambda a, b: a - b)

    def __mul__(self, o):
        return self._op(o, lambda a, b: a * b)

    def __rmul__(self, o):
        return self.__mul__(o)


class Vec4(Vec3):
    def __init__(self, *a):
        if len(a) == 1 and isinstance(a[0], (list, tuple)):
            super().__init__([float(v) for v in a[0]][:4])
        elif len(a) == 1:
            super().__init__([float(a[0])] * 4)
        else:
            super().__init__([float(v) for v in a[:4]])

    @property
    def rgb(self):
        return Vec3(self[:3])


def _mix(a, b, t):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a + (b - a) * t
    va, vb = Vec3(a), Vec3(b)
    return Vec3([x + (y - x) * t for x, y in zip(va, vb)])


def _strip_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def uniforms(src):
    """Uniform name -> default value, from `uniform <type> <name> = <value>;`"""
    env = {}
    pat = re.compile(
        r"uniform\s+(vec[234]|float|int)\s+(\w+)\s*(?::[^=;]+)?=\s*([^;]+);")
    for typ, name, expr in pat.findall(_strip_comments(src)):
        try:
            env[name] = evaluate(expr, env, {})
        except Exception:
            continue
    return env


def locals_before(src, expr):
    """Scalar `float name = ...;` declarations the EMISSION expression uses.

    The terrain fill is `col * fill_k + ...` where fill_k is a local, so the
    expression cannot be evaluated without replaying its definition.
    """
    body = _strip_comments(src)
    out = []
    for name in re.findall(r"\b([A-Za-z_]\w*)\b", expr):
        m = re.search(r"^\s*float\s+%s\s*=\s*([^;]+);" % re.escape(name),
                      body, re.M)
        if m:
            out.append((name, m.group(1).strip()))
    return out


def emission_expr(src):
    """The (last) EMISSION assignment in the shader."""
    found = re.findall(r"^\s*EMISSION\s*=\s*(.+?);", _strip_comments(src), re.M)
    if not found:
        return None
    return found[-1].strip()


def evaluate(expr, env, sweep):
    """Evaluate a shader expression in linear colour.

    Only the constructs these fill expressions actually use are supported; an
    unsupported construct raises rather than being guessed at.
    """
    ns = dict(env)
    ns.update(sweep)
    ns.update({
        "vec3": Vec3, "vec4": Vec4, "mix": _mix,
        "clamp": lambda x, a, b: max(a, min(b, x)),
        "abs": abs, "max": max, "min": min, "pow": pow, "sin": math.sin,
    })
    return eval(expr, {"__builtins__": {}}, ns)  # noqa: S307 - expressions are ours


def to_lum(v):
    if isinstance(v, (int, float)):
        return float(v)
    if hasattr(v, "rgb"):
        v = v.rgb
    return luminance(list(v))


def analyse(path, verbose):
    with open(path) as fh:
        src = fh.read()
    expr = emission_expr(src)
    if expr is None:
        return None
    env = uniforms(src)
    # Replay local scalars in declaration order so they see each other.
    for name, sub in locals_before(src, expr):
        try:
            env[name] = evaluate(sub, env, {"col": 1.0, "base": 1.0,
                                            "patch": 0.5})
        except Exception:
            pass
    local_defs = locals_before(src, expr)
    samples = []
    for alb in ALBEDOS:
        # Sweep the shading variables across their meaningful range so the
        # fill is checked everywhere it matters, not only at one midpoint.
        for patch in (0.0, 0.5, 1.0):
            sweep = {k: alb for k in ("col", "base")}
            sweep["patch"] = patch
            sweep["t"] = 0.5
            sweep["v_tint"] = 0.5
            # Locals depend on the swept values, so evaluate them per sample.
            local_env = dict(env)
            for name, sub in local_defs:
                try:
                    local_env[name] = evaluate(sub, local_env, sweep)
                except Exception:
                    pass
            try:
                val = to_lum(evaluate(expr, local_env, sweep))
            except Exception as exc:
                raise SystemExit("%s: cannot evaluate `%s`: %s" % (path, expr, exc))
            samples.append((alb, patch, val))
    if verbose:
        print("%s\n  EMISSION = %s" % (path, expr))
        for alb, patch, val in samples:
            print("    albedo %.2f patch %.1f -> fill %.4f" % (alb, patch, val))
    return samples


def main(argv):
    verbose = "--verbose" in argv
    results = []
    for path, _vars in SURFACES:
        samples = analyse(path, verbose)
        if samples is None:
            print("::error::%s has no EMISSION expression" % path)
            return 1
        results.append((path, samples))

    # Compare each surface against the terrain, which is the reference the
    # meadow has to sit in.
    ref_path, ref = results[0]
    worst = 0.0
    worst_desc = ""
    bad = False
    for path, samples in results[1:]:
        for (alb, patch, ref_val), (_, _, val) in zip(ref, samples):
            if ref_val <= 1e-4 or val <= 1e-4:
                continue
            spread = max(val / ref_val, ref_val / val)
            if spread > worst:
                worst = spread
                worst_desc = ("everywhere" if spread > 50 else
                              "albedo %.2f patch %.1f: %s %.4f vs %s %.4f"
                              % (alb, patch, path.split("/")[-1], val,
                                 ref_path.split("/")[-1], ref_val))
            if spread > MAX_SPREAD:
                bad = True

    # Absolute band, checked on every surface including the reference.
    for path, samples in results:
        hi = max(v for _, _, v in samples)
        lo = min(v for _, _, v in samples)
        if hi > FILL_MAX:
            print("::error title=fill::%s fills to %.3f at the bright end "
                  "(limit %.2f) - sunlit ground will clip"
                  % (path, hi, FILL_MAX))
            bad = True
        if lo < FILL_MIN:
            print("::error title=fill::%s fills to only %.3f at the dark end "
                  "(floor %.2f) - shadowed ground will read as a hole"
                  % (path, lo, FILL_MIN))
            bad = True

    print("fill check: %d surfaces, worst spread %.2fx (limit %.1fx)"
          % (len(results), worst, MAX_SPREAD))
    if worst_desc:
        print("  worst: %s" % worst_desc)
    if bad:
        print("::error title=fill::shadow fill scales disagree by %.1fx - the "
              "darker surface will read as a hole" % worst)
        return 1
    print("OK - shadow fills are on a consistent scale")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
