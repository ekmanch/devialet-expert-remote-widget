"""Analysis + report for a harness run directory (Phase 7.2.0).

Reads runs/<stamp>/{states.json,run.json,coords/*.json,shots/*.png} and
writes report.md, summary.json and diffs/*.png into the same directory.

Checks, in report order:
1. Control identity - <state> vs <state>__control coordinates must be
   identical (any difference = harness/render instability); pixel diff
   count/bbox/row bands are reported (expected ~0 outside animated
   regions such as a blinking caret or the Booting pulse).
2. Popup geometry - window w/h and mainItem implicit w/h per state, so a
   whole-popup resize (investigation document §1's master finding) shows
   in one table.
3. Single-dimension flips - for every pair of states differing in exactly
   one dimension (scenarios.adjacent_pairs), every element whose window
   x/y/w/h differs, grouped by element. An optional expected.json allowlist
   ([{"key": <regex>, "dim": <dim or "*">, "note": ...}]) splits hits into
   allowed and unexpected.
4. Pixel diffs for the same pairs (exact equality, Phase 4.5.3's method):
   differing-pixel count, bbox, row bands, diff image. When a state has a
   control capture its self-differing pixels form a noise mask that is
   excluded from that state's pair diffs (--noise-mask makes every state
   have one).

Exit code: 1 = control coordinates unstable, 2 = unexpected element
moves, 0 otherwise.
"""

import json
import os
import re
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenarios  # noqa: E402

# Move test diffs on the window-space CENTER (wcx/wcy), not the (0,0)
# corner: a rotated item (the amp caret's 180deg flip) maps its origin
# corner to the opposite corner while its layout box is unmoved - the
# corner is a false positive, the center is rotation-invariant and still
# tracks a real translation 1:1. wx/wy stay in the dump for debugging.
GEOM = ("wcx", "wcy", "w", "h")
MAX_BANDS = 12


def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_coords(run_dir, cid):
    path = os.path.join(run_dir, "coords", cid + ".json")
    if not os.path.exists(path):
        return None
    d = _load(path)
    items = {}
    dup = []
    for rec in d.get("items", []):
        if rec["key"] in items:
            dup.append(rec["key"])
        items[rec["key"]] = rec
    d["by_key"] = items
    d["duplicate_keys"] = dup
    return d


def geom_delta(a, b):
    # Only keys present in both records (a pre-center run lacks wcx/wcy).
    return {k: b[k] - a[k] for k in GEOM if k in a and k in b and a[k] != b[k]}


def compare_items(ia, ib):
    out = []
    for key in sorted(set(ia) | set(ib)):
        if key not in ia:
            out.append({"key": key, "kind": "only_in_b", "cls": ib[key]["cls"], "path": ib[key].get("path", key)})
        elif key not in ib:
            out.append({"key": key, "kind": "only_in_a", "cls": ia[key]["cls"], "path": ia[key].get("path", key)})
        else:
            d = geom_delta(ia[key], ib[key])
            if d:
                out.append({
                    "key": key, "kind": "moved", "cls": ia[key]["cls"], "path": ia[key].get("path", key),
                    "dx": d.get("wcx", 0.0), "dy": d.get("wcy", 0.0), "dw": d.get("w", 0.0), "dh": d.get("h", 0.0),
                    "textA": ia[key].get("text"), "textB": ib[key].get("text"),
                    "visA": ia[key]["vis"], "visB": ib[key]["vis"],
                })
    return out


def load_rgb(path):
    return np.asarray(Image.open(path).convert("RGB"))


def diff_mask(a, b):
    if a.shape != b.shape:
        return None
    return (a != b).any(axis=2)


def mask_stats(m):
    count = int(m.sum())
    if count == 0:
        return {"count": 0, "bbox": None, "bands": []}
    ys, xs = np.nonzero(m)
    bbox = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1]
    rows = m.sum(axis=1)
    bands = []
    y = 0
    n = len(rows)
    while y < n:
        if rows[y] > 0:
            y0 = y
            while y < n and rows[y] > 0:
                y += 1
            bands.append([y0, y, int(rows[y0:y].sum())])
        else:
            y += 1
    return {"count": count, "bbox": bbox, "bands": bands}


def save_diff_image(b_rgb, m, out):
    img = b_rgb.copy()
    img[m] = [255, 0, 0]
    Image.fromarray(img).save(out)


def load_expected(path):
    if not path or not os.path.exists(path):
        return []
    rules = _load(path)
    return [(re.compile(r["key"]), r.get("dim", "*"), r.get("note", "")) for r in rules]


def is_expected(rules, key, dim, path=None):
    for rx, rdim, _ in rules:
        if (rx.search(key) or (path and rx.search(path))) and (rdim == "*" or rdim == dim):
            return True
    return False


def fmt(v):
    if isinstance(v, float):
        return f"{v:+.3f}" if v else "0"
    return str(v)


def run(run_dir, expected_path=None, write=True):
    states = _load(os.path.join(run_dir, "states.json"))
    run_info = _load(os.path.join(run_dir, "run.json")) if os.path.exists(os.path.join(run_dir, "run.json")) else {}
    rules = load_expected(expected_path or os.path.join(run_dir, "expected.json"))
    shots = os.path.join(run_dir, "shots")
    diffs_dir = os.path.join(run_dir, "diffs")
    if write:
        os.makedirs(diffs_dir, exist_ok=True)

    coords = {}
    for st in states:
        for cid in st["captures"]:
            c = load_coords(run_dir, cid)
            if c is not None:
                coords[cid] = c

    warnings = []

    def warn(msg):
        if msg not in warnings:
            warnings.append(msg)

    for w in run_info.get("warnings", []):
        warn(w)
    for cid, c in coords.items():
        if c["duplicate_keys"]:
            warn(f"{cid}: duplicate keys {sorted(set(c['duplicate_keys']))[:5]} (objectName reused?)")
        if c.get("end", {}).get("count") is not None and c["end"]["count"] != len(c.get("items", [])):
            warn(f"{cid}: probe logged {c['end']['count']} items but {len(c['items'])} were parsed (journald drop?)")
        for w in c.get("begin", {}).get("uiWarnings", []) or []:
            warn(f"{cid}: {w}")
        # Phase 7.3.0: the overlay-is-not-a-second-window check, free on
        # every state - the in-window Popup must leave the flyout window
        # itself visible and active. `active` is absent in pre-7.3.0 runs.
        win = c.get("begin", {}).get("win", {})
        if "active" in win and not (win.get("visible") and win.get("active")):
            warn(f"{cid}: flyout window not visible+active (visible={win.get('visible')}, active={win.get('active')}) - a second window may have taken activation")

    # ---- 1. control identity ------------------------------------------
    control = []
    noise_masks = {}
    for st in states:
        sid = st["id"]
        ccid = sid + "__control"
        if ccid not in st["captures"] or sid not in coords or ccid not in coords:
            continue
        moves = compare_items(coords[sid]["by_key"], coords[ccid]["by_key"])
        entry = {"state": sid, "coord_diffs": moves, "pixels": None}
        pa, pb = os.path.join(shots, sid + ".png"), os.path.join(shots, ccid + ".png")
        if os.path.exists(pa) and os.path.exists(pb):
            m = diff_mask(load_rgb(pa), load_rgb(pb))
            if m is None:
                entry["pixels"] = {"error": "size mismatch"}
            else:
                entry["pixels"] = mask_stats(m)
                noise_masks[sid] = m
                if write and entry["pixels"]["count"]:
                    save_diff_image(load_rgb(pb), m, os.path.join(diffs_dir, f"control__{sid}.png"))
        control.append(entry)
    control_unstable = any(e["coord_diffs"] for e in control)

    # ---- 2. popup geometry ---------------------------------------------
    geometry = {}
    for st in states:
        c = coords.get(st["id"])
        if not c:
            continue
        b = c["begin"]
        key = json.dumps({"win": [b["win"]["w"], b["win"]["h"]], "mainItem": [b["mainItem"]["w"], b["mainItem"]["h"], b["mainItem"]["iw"], b["mainItem"]["ih"]]})
        geometry.setdefault(key, []).append(st["id"])

    # ---- 3. single-dimension flips + 4. pixel diffs --------------------
    pairs = scenarios.adjacent_pairs(states)
    unexpected, allowed, pixel_rows = [], [], []
    rgb_cache = {}

    def rgb(cid):
        if cid not in rgb_cache:
            p = os.path.join(shots, cid + ".png")
            rgb_cache[cid] = load_rgb(p) if os.path.exists(p) else None
            if len(rgb_cache) > 64:
                rgb_cache.pop(next(iter(rgb_cache)))
        return rgb_cache[cid]

    for a, b, dim in pairs:
        if a in coords and b in coords:
            for mv in compare_items(coords[a]["by_key"], coords[b]["by_key"]):
                rec = dict(mv, a=a, b=b, dim=dim)
                (allowed if is_expected(rules, mv["key"], dim, mv.get("path")) else unexpected).append(rec)
        ra, rb = rgb(a), rgb(b)
        if ra is None or rb is None:
            continue
        m = diff_mask(ra, rb)
        if m is None:
            pixel_rows.append({"a": a, "b": b, "dim": dim, "error": "size mismatch"})
            continue
        masked = False
        for sid in (a, b):
            if sid in noise_masks and noise_masks[sid].shape == m.shape:
                m = m & ~noise_masks[sid]
                masked = True
        stats = mask_stats(m)
        stats.update({"a": a, "b": b, "dim": dim, "noise_masked": masked})
        pixel_rows.append(stats)
        if write and stats["count"]:
            save_diff_image(rb, m, os.path.join(diffs_dir, f"{dim}__{a}__vs__{b}.png"))

    summary = {
        "run_dir": run_dir,
        "states": len(states),
        "captures_parsed": len(coords),
        "pairs": len(pairs),
        "control": control,
        "control_unstable": control_unstable,
        "geometry": {k: v for k, v in geometry.items()},
        "unexpected_moves": unexpected,
        "allowed_moves": allowed,
        "pixel": pixel_rows,
        "warnings": warnings,
    }
    exit_code = 1 if control_unstable else (2 if unexpected else 0)
    summary["exit_code"] = exit_code
    if write:
        with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=1, default=str)
        with open(os.path.join(run_dir, "report.md"), "w", encoding="utf-8") as f:
            f.write(render_report(summary, run_info, coords))
    return summary


def compare_runs(run_a, run_b):
    """Coordinate diff of every capture id present in both runs - used for
    run-to-run stability and the settle-floor check (same set at two
    settle values must yield identical coordinates)."""
    sa = _load(os.path.join(run_a, "states.json"))
    sb = _load(os.path.join(run_b, "states.json"))
    ids_a = [c for st in sa for c in st["captures"]]
    ids_b = {c for st in sb for c in st["captures"]}
    common = [c for c in ids_a if c in ids_b]
    result = {"run_a": run_a, "run_b": run_b, "common": len(common), "only_a": len(ids_a) - len(common),
              "only_b": len(ids_b) - len(common), "diffs": {}, "geometry_diffs": {}}
    for cid in common:
        ca, cb = load_coords(run_a, cid), load_coords(run_b, cid)
        if ca is None or cb is None:
            continue
        moves = compare_items(ca["by_key"], cb["by_key"])
        if moves:
            result["diffs"][cid] = moves
        ga, gb = ca["begin"]["win"], cb["begin"]["win"]
        if (ga["w"], ga["h"]) != (gb["w"], gb["h"]):
            result["geometry_diffs"][cid] = [ga, gb]
    result["identical"] = not result["diffs"] and not result["geometry_diffs"]
    return result


def render_report(s, run_info, coords):
    L = []
    L.append(f"# Flyout harness report — `{os.path.basename(s['run_dir'].rstrip('/'))}`\n")
    L.append(f"- states: {s['states']}, captures parsed: {s['captures_parsed']}, single-dimension pairs: {s['pairs']}")
    if run_info:
        L.append(f"- selection: `{run_info.get('selection')}`, settle: {run_info.get('settle_ms')} ms, crop: {run_info.get('crop')}, avg per state: {run_info.get('avg_state_seconds')} s")
    verdict = {0: "PASS — control stable, no unexpected element moves", 1: "FAIL — control capture coordinates differ (harness/render instability)", 2: "FAIL — unexpected element moves on single-dimension flips"}[s["exit_code"]]
    L.append(f"- **verdict: {verdict}**\n")

    L.append("## 1. Control identity (same state captured twice)\n")
    if not s["control"]:
        L.append("_no control captures_\n")
    for e in s["control"]:
        L.append(f"### `{e['state']}`")
        if e["coord_diffs"]:
            L.append(f"- coordinates: **{len(e['coord_diffs'])} element(s) differ** — harness instability, see below")
            for mv in e["coord_diffs"][:20]:
                L.append(f"  - `{mv['key']}` {mv['kind']} " + (f"Δx={fmt(mv['dx'])} Δy={fmt(mv['dy'])} Δw={fmt(mv['dw'])} Δh={fmt(mv['dh'])}" if mv["kind"] == "moved" else ""))
        else:
            L.append("- coordinates: identical")
        px = e["pixels"]
        if px is None:
            L.append("- pixels: _no screenshots_")
        elif "error" in px:
            L.append(f"- pixels: {px['error']}")
        else:
            L.append(f"- pixels: {px['count']} differing, bbox {px['bbox']}, row bands {px['bands'][:MAX_BANDS]}" + (" (noise: expected only in animated regions — caret blink, Booting pulse)" if px["count"] else ""))
        L.append("")

    L.append("## 2. Popup geometry across states\n")
    L.append("| window w×h | mainItem w×h (implicit w×h) | states |")
    L.append("|---|---|---|")
    for k, ids in s["geometry"].items():
        g = json.loads(k)
        L.append(f"| {g['win'][0]}×{g['win'][1]} | {g['mainItem'][0]}×{g['mainItem'][1]} ({g['mainItem'][2]}×{g['mainItem'][3]}) | {len(ids)}" + (f" (e.g. `{ids[0]}`)" if len(s["geometry"]) > 1 else "") + " |")
    if len(s["geometry"]) > 1:
        L.append("\n**More than one popup geometry across states — the whole popup resizes (§1 master finding).**")
    L.append("")

    def moves_section(title, moves):
        L.append(f"## {title}\n")
        if not moves:
            L.append("_none_\n")
            return
        by_key = {}
        for mv in moves:
            by_key.setdefault(mv["key"], []).append(mv)
        L.append(f"{len(moves)} hit(s) on {len(by_key)} element(s).\n")
        for key, lst in sorted(by_key.items(), key=lambda kv: -len(kv[1])):
            L.append(f"### `{key}` ({lst[0]['cls']}) — {len(lst)} hit(s)")
            L.append("| dim | from | to | Δx | Δy | Δw | Δh | text before → after |")
            L.append("|---|---|---|---|---|---|---|---|")
            for mv in lst[:40]:
                fa = mv["a"].split(f"{mv['dim']}=")[1].split("_")[0] if f"{mv['dim']}=" in mv["a"] else "?"
                fb = mv["b"].split(f"{mv['dim']}=")[1].split("_")[0] if f"{mv['dim']}=" in mv["b"] else "?"
                if mv["kind"] != "moved":
                    L.append(f"| {mv['dim']} | {fa} | {fb} | {mv['kind']} | | | | |")
                else:
                    L.append(f"| {mv['dim']} | {fa} | {fb} | {fmt(mv['dx'])} | {fmt(mv['dy'])} | {fmt(mv['dw'])} | {fmt(mv['dh'])} | {mv['textA']!r} → {mv['textB']!r} |")
            if len(lst) > 40:
                L.append(f"| … | | | {len(lst) - 40} more | | | | |")
            L.append("")

    moves_section("3. Unexpected element moves (single-dimension flips)", s["unexpected_moves"])
    moves_section("3b. Allowed element moves (matched expected.json)", s["allowed_moves"])

    L.append("## 4. Pixel diffs (single-dimension flips)\n")
    rows = [r for r in s["pixel"] if "error" not in r]
    nz = [r for r in rows if r["count"]]
    L.append(f"{len(rows)} pair(s) compared, {len(nz)} with differing pixels. Full list in summary.json; diff images in diffs/.\n")
    if nz:
        L.append("| dim | a | b | px | bbox | bands (y0,y1,px) | noise-masked |")
        L.append("|---|---|---|---|---|---|---|")
        for r in sorted(nz, key=lambda r: -r["count"])[:60]:
            L.append(f"| {r['dim']} | `{r['a']}` | `{r['b']}` | {r['count']} | {r['bbox']} | {r['bands'][:6]} | {r['noise_masked']} |")
        L.append("")
    errs = [r for r in s["pixel"] if "error" in r]
    if errs:
        L.append(f"{len(errs)} pair(s) could not be compared: {errs[:5]}\n")

    L.append("## 5. Warnings\n")
    L.extend(f"- {w}" for w in s["warnings"]) if s["warnings"] else L.append("_none_")
    L.append("")
    return "\n".join(L)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: analyze.py <run-dir> [expected.json]", file=sys.stderr)
        sys.exit(2)
    summ = run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    print(f"report: {os.path.join(sys.argv[1], 'report.md')} (exit {summ['exit_code']})")
    sys.exit(summ["exit_code"])
