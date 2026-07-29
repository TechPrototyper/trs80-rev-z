#!/usr/bin/env python3
"""Deterministic netlist extractor for KiCad 7/8 .kicad_sch sheets.

Research tooling for the schematic walkthroughs in docs/chapters/: parses the
s-expression, places library pins through the instance transform, and resolves
connectivity via wires, junctions, bus entries and labels (local /
hierarchical / global / power symbols). Used from chapter 4 on against
RetroStack's MIT-licensed Rev G recreation (see docs/RESOURCES.md); it
replaces the AI-agent extraction passes of chapters 1-3 and was validated by
reproducing chapter 3's independently extracted VideoAccessMultiplexer
netlist exactly.

Transform calibration: the exact lib->sheet pin transform (Y flip, rotation
sign, mirror order) is picked automatically per sheet as the variant that
lands the most pins on wire endpoints.

Usage: kicad_nets.py FILE.kicad_sch [MORE.kicad_sch ...]
"""

import math
import re
import sys

# ----------------------------------------------------------------------
# s-expression parsing
# ----------------------------------------------------------------------

def tokenize(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c in "()":
            yield c
            i += 1
        elif c == '"':
            j = i + 1
            out = []
            while j < n:
                if text[j] == "\\" and j + 1 < n:
                    out.append(text[j + 1])
                    j += 2
                elif text[j] == '"':
                    break
                else:
                    out.append(text[j])
                    j += 1
            yield ("STR", "".join(out))
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "()":
                j += 1
            yield ("ATOM", text[i:j])
            i = j


def parse(text):
    stack = [[]]
    for tok in tokenize(text):
        if tok == "(":
            stack.append([])
        elif tok == ")":
            done = stack.pop()
            stack[-1].append(done)
        else:
            stack[-1].append(tok[1])
    return stack[0][0]


def tag(node):
    return node[0] if isinstance(node, list) and node and isinstance(node[0], str) else None


def kids(node, name):
    return [c for c in node[1:] if tag(c) == name]


def kid(node, name):
    k = kids(node, name)
    return k[0] if k else None


def atoms(node):
    return [c for c in node[1:] if isinstance(c, str)]


# ----------------------------------------------------------------------
# model extraction
# ----------------------------------------------------------------------

def f(x):
    return float(x)


def q(v):
    """quantize to 5 um — immune to float artifacts on the 1.27 mm grid"""
    return int(round(v * 200))


def get_at(node):
    a = kid(node, "at")
    v = atoms(a)
    return (f(v[0]), f(v[1]), f(v[2]) if len(v) > 2 else 0.0)


class LibPin:
    def __init__(self, num, name, x, y, ang, etype):
        self.num, self.name, self.x, self.y, self.ang, self.etype = num, name, x, y, ang, etype


def load_lib(root):
    """lib name -> unit -> [LibPin]  (unit 0 = common pins)."""
    libs = {}
    ls = kid(root, "lib_symbols")
    if not ls:
        return libs
    for sym in kids(ls, "symbol"):
        name = sym[1]
        units = {}
        def grab(sub, unit):
            for p in kids(sub, "pin"):
                x, y, ang = get_at(p)
                num = kid(p, "number")[1]
                pnm = kid(p, "name")[1]
                etype = p[1] if len(p) > 1 and isinstance(p[1], str) else "?"
                units.setdefault(unit, []).append(LibPin(num, pnm, x, y, ang, etype))
        grab(sym, 0)
        for sub in kids(sym, "symbol"):
            m = re.match(r".*_(\d+)_(\d+)$", sub[1])
            unit = int(m.group(1)) if m else 0
            grab(sub, unit)
        libs[name] = units
    return libs


TRANSFORMS = {}

def make_transform(flip_y, rot_sign, mirror_first):
    def t(px, py, ang, mirror, ix, iy):
        if mirror_first:
            if mirror == "x":
                py = -py
            elif mirror == "y":
                px = -px
        a = math.radians(rot_sign * ang)
        rx = px * math.cos(a) - py * math.sin(a)
        ry = px * math.sin(a) + py * math.cos(a)
        if not mirror_first:
            if mirror == "x":
                ry = -ry
            elif mirror == "y":
                rx = -rx
        if flip_y:
            ry = -ry
        return (ix + rx, iy + ry)
    return t

for fy in (True, False):
    for rs in (1, -1):
        for mf in (True, False):
            TRANSFORMS[(fy, rs, mf)] = make_transform(fy, rs, mf)


class Instance:
    def __init__(self, node):
        self.lib_id = kid(node, "lib_id")[1]
        self.x, self.y, self.ang = get_at(node)
        m = kid(node, "mirror")
        self.mirror = atoms(m)[0] if m else None
        u = kid(node, "unit")
        self.unit = int(atoms(u)[0]) if u else 1
        self.ref = self.value = "?"
        for p in kids(node, "property"):
            if p[1] == "Reference":
                self.ref = p[2]
            elif p[1] == "Value":
                self.value = p[2]

    @property
    def is_power(self):
        return self.lib_id.startswith("power:")


def pin_positions(inst, libs, transform):
    lib = libs.get(inst.lib_id) or libs.get(inst.lib_id.split(":")[-1])
    if lib is None:
        for k in libs:
            if k.endswith(":" + inst.lib_id.split(":")[-1]):
                lib = libs[k]
                break
    if lib is None:
        return []
    pins = list(lib.get(0, [])) + list(lib.get(inst.unit, []))
    out, seen = [], set()
    for p in pins:
        if p.num in seen:      # body-style subsymbols repeat the pins
            continue
        seen.add(p.num)
        x, y = transform(p.x, p.y, inst.ang, inst.mirror, inst.x, inst.y)
        out.append((p, x, y))
    return out


# ----------------------------------------------------------------------
# connectivity
# ----------------------------------------------------------------------

class DSU:
    def __init__(self):
        self.p = {}

    def find(self, a):
        self.p.setdefault(a, a)
        while self.p[a] != a:
            self.p[a] = self.p[self.p[a]]
            a = self.p[a]
        return a

    def union(self, a, b):
        self.p[self.find(a)] = self.find(b)


def on_segment(pt, seg, tol=0.01):
    (x1, y1), (x2, y2) = seg
    x, y = pt
    if min(x1, x2) - tol <= x <= max(x1, x2) + tol and min(y1, y2) - tol <= y <= max(y1, y2) + tol:
        return abs((x2 - x1) * (y - y1) - (y2 - y1) * (x - x1)) <= tol * (abs(x2 - x1) + abs(y2 - y1) + 1)
    return False


def resolve(path):
    root = parse(open(path, encoding="utf-8").read())
    libs = load_lib(root)

    instances = [Instance(n) for n in kids(root, "symbol")]
    wires, buses = [], []
    for w in kids(root, "wire"):
        pts = [(f(p[1]), f(p[2])) for p in kids(kid(w, "pts"), "xy")]
        for a, b in zip(pts, pts[1:]):
            wires.append((a, b))
    for w in kids(root, "bus"):
        pts = [(f(p[1]), f(p[2])) for p in kids(kid(w, "pts"), "xy")]
        for a, b in zip(pts, pts[1:]):
            buses.append((a, b))
    for be in kids(root, "bus_entry"):
        x, y, _ = get_at(be)
        s = atoms(kid(be, "size"))
        wires.append(((x, y), (x + f(s[0]), y + f(s[1]))))
    junctions = [tuple(map(f, atoms(kid(j, "at"))[:2])) for j in kids(root, "junction")]
    no_connects = [tuple(map(f, atoms(kid(j, "at"))[:2])) for j in kids(root, "no_connect")]

    labels = []          # (kind, text, (x, y), shape)
    for kind in ("label", "global_label", "hierarchical_label"):
        for l in kids(root, kind):
            x, y, _ = get_at(l)
            sh = kid(l, "shape")
            labels.append((kind, l[1], (x, y),
                           atoms(sh)[0] if sh else None))
    texts = [t[1] for t in kids(root, "text")]

    # pick the transform variant that lands the most pins on wire endpoints
    endpoints = set()
    for a, b in wires:
        endpoints.add((q(a[0]), q(a[1])))
        endpoints.add((q(b[0]), q(b[1])))
    best, best_hits = None, -1
    for key, tf in TRANSFORMS.items():
        hits = 0
        for inst in instances:
            if inst.is_power:
                continue
            for _, x, y in pin_positions(inst, libs, tf):
                if (q(x), q(y)) in endpoints:
                    hits += 1
        if hits > best_hits:
            best, best_hits = key, hits
    tf = TRANSFORMS[best]

    dsu = DSU()
    def key(pt):
        return (q(pt[0]), q(pt[1]))

    for a, b in wires:
        dsu.union(("w", key(a)), ("w", key(b)))
    for j in junctions:
        for a, b in wires:
            if on_segment(j, (a, b)):
                dsu.union(("w", key(j)), ("w", key(a)))
    # wire endpoint landing mid-segment of another wire counts as connected
    # (KiCad treats a wire ending on a wire as a connection)
    for a, b in wires:
        for pt in (a, b):
            for c, d in wires:
                if (c, d) is (a, b):
                    continue
                if on_segment(pt, (c, d)):
                    dsu.union(("w", key(pt)), ("w", key(c)))

    pin_map = []          # (inst, LibPin, point)
    total_pins = miss = 0
    for inst in instances:
        for p, x, y in pin_positions(inst, libs, tf):
            pt = (x, y)
            total_pins += 1
            if key(pt) in endpoints:
                dsu.union(("w", key(pt)), ("p", inst.ref, p.num, id(inst)))
            else:
                hit = False
                for c, d in wires:
                    if on_segment(pt, (c, d)):
                        dsu.union(("w", key(c)), ("p", inst.ref, p.num, id(inst)))
                        hit = True
                        break
                if not hit:
                    dsu.union(("w", key(pt)), ("p", inst.ref, p.num, id(inst)))
                    miss += 1
            pin_map.append((inst, p, pt))

    # net names — a label names whatever wire its anchor touches (endpoint
    # or anywhere along a segment)
    names = {}
    for kind, text, pt, shape in labels:
        if key(pt) not in endpoints:
            for c, d in wires:
                if on_segment(pt, (c, d)):
                    dsu.union(("w", key(pt)), ("w", key(c)))
                    break
        r = dsu.find(("w", key(pt)))
        nm = text + (f" [{kind[:4]}:{shape}]" if kind == "hierarchical_label" else "")
        names.setdefault(r, set()).add(nm)
    for inst in instances:
        if inst.is_power:
            for p, x, y in pin_positions(inst, libs, tf):
                r = dsu.find(("w", (q(x), q(y))))
                names.setdefault(r, set()).add(inst.value)

    nc_roots = {dsu.find(("w", key(p))) for p in no_connects}

    anon_ids = {}
    def netname(root_):
        if root_ in names:
            return " = ".join(sorted(names[root_]))
        if root_ in nc_roots:
            return "<no_connect>"
        if root_ not in anon_ids:
            anon_ids[root_] = len(anon_ids) + 1
        return f"<anon {anon_ids[root_]}>"

    # report
    print(f"SHEET {path.split('/')[-1]}")
    print(f"  transform={best} pin-endpoint hits={best_hits}/{total_pins} floating={miss}")
    for t in texts:
        print(f"  TEXT: {t!r}")
    hier = [(l[1], l[3]) for l in labels if l[0] == "hierarchical_label"]
    print("  HIERARCHICAL: " + ", ".join(f"{n}({s})" for n, s in sorted(set(hier))))
    by_ref = {}
    for inst, p, pt in pin_map:
        if inst.is_power:
            continue
        by_ref.setdefault((inst.ref, inst.lib_id.split(":")[-1]), []).append((inst, p, pt))
    for (ref, lib), pins in sorted(by_ref.items()):
        units = sorted({i.unit for i, _, _ in pins})
        print(f"\n  {ref}  {lib}  (units {units})")
        for inst, p, pt in sorted(pins, key=lambda e: (e[0].unit, int(e[1].num) if e[1].num.isdigit() else 999)):
            r = dsu.find(("p", inst.ref, p.num, id(inst)))
            nm = p.name if p.name != "~" else ""
            print(f"    u{inst.unit} pin {p.num:>3} {nm:<12} ({p.etype[:3]}) -> {netname(r)}")


if __name__ == "__main__":
    for patharg in sys.argv[1:]:
        resolve(patharg)
        print()
