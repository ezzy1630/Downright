#!/usr/bin/env python3
"""WCAG 2.1 contrast checker for Downright theme JSONs.

Body/secondary text, headings, links, code tokens >= 4.5:1; faint text,
accents, code comments >= 3.0:1. Exit code 2 on any FAIL.
"""

import json
import os
import sys

THEME_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "Sources", "MarkdownRender", "Themes")

PALETTE_PAIRS = [
    ("text", "background", 4.5, "text"),
    ("heading", "background", 4.5, "heading"),
    ("textSecondary", "background", 4.5, "textSecondary"),
    ("textFaint", "background", 3.0, "textFaint"),
    ("link", "background", 4.5, "link"),
    ("accent", "background", 3.0, "accent"),
    ("marker", "background", 4.5, "marker"),
    ("railTick", "background", 3.0, "railTick"),
    ("pathMissing", "background", 4.5, "pathMissing"),
    ("searchHit", "background", 3.0, "searchHit"),
    ("searchHitCurrent", "background", 3.0, "searchHitCurrent"),
    ("calloutNote", "background", 3.0, "calloutNote"),
    ("calloutWarning", "background", 3.0, "calloutWarning"),
    ("calloutSuccess", "background", 3.0, "calloutSuccess"),
    ("calloutDanger", "background", 3.0, "calloutDanger"),
    ("changeAdded", "background", 3.0, "changeAdded"),
    ("changeRemoved", "background", 3.0, "changeRemoved"),
    ("changeModified", "background", 3.0, "changeModified"),
    ("textSecondary", "surface", 3.0, "placeholderOnGlass"),
    ("textSecondary", "surface", 3.0, "secondaryGlyphOnBand"),
]

CODE_PAIRS = [
    ("keyword", 4.5),
    ("string", 4.5),
    ("number", 4.5),
    ("comment", 3.0),
    ("type", 4.5),
    ("function", 4.5),
    ("variable", 4.5),
    ("constant", 4.5),
    ("operator", 4.5),
    ("punctuation", 4.5),
    ("attribute", 4.5),
    ("diffAdded", 4.5),
    ("diffRemoved", 4.5),
    ("diffHeader", 4.5),
]


def parse_hex(value):
    """Return (r, g, b, a) with channels in [0, 1] or None if not hex."""
    if not isinstance(value, str) or not value.startswith("#"):
        return None
    digits = value[1:]
    if len(digits) == 3:
        digits = "".join(ch * 2 for ch in digits)
    if len(digits) == 4:
        digits = "".join(ch * 2 for ch in digits)
    if len(digits) not in (6, 8):
        return None
    try:
        vals = [int(digits[i:i + 2], 16) / 255.0 for i in range(0, 6, 2)]
    except ValueError:
        return None
    alpha = int(digits[6:8], 16) / 255.0 if len(digits) == 8 else 1.0
    return (vals[0], vals[1], vals[2], alpha)


def flatten(fg, bg):
    """Flatten fg (r,g,b,a) onto opaque bg (r,g,b) using source-over."""
    r, g, b, a = fg
    br, bg_, bb = bg
    return (
        r * a + br * (1.0 - a),
        g * a + bg_ * (1.0 - a),
        b * a + bb * (1.0 - a),
    )


def linearize(channel):
    return channel / 12.92 if channel <= 0.03928 else ((channel + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)


def contrast(fg, bg):
    """fg/bg are (r,g,b) tuples. Return contrast ratio."""
    l1 = luminance(fg)
    l2 = luminance(bg)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def pair_hex(fg_raw, bg_raw):
    """Return (fg_rgb, bg_rgb) with alpha flattened, or None if unparseable."""
    fg = parse_hex(fg_raw)
    bg = parse_hex(bg_raw)
    if fg is None or bg is None:
        return None
    bg_rgb = bg[:3]
    if bg[3] < 1.0:
        return None
    if fg[3] < 1.0:
        fg = flatten(fg, bg_rgb)
    return (fg[:3], bg_rgb)


def color_label(value):
    return value if isinstance(value, str) and value.startswith("#") else (value if isinstance(value, str) else str(value))


def check_theme(name, data, results):
    rows = []
    palette = data.get("palette", {})
    code = data.get("code", {})
    background = palette.get("background")
    code_background = palette.get("codeBackground", background)

    for key, bg_key, threshold, label in PALETTE_PAIRS:
        fg_raw = palette.get(key)
        bg_raw = palette.get(bg_key, background)
        if fg_raw is None or bg_raw is None:
            rows.append((label, color_label(fg_raw) if fg_raw else "MISSING", "-", "-", "SKIP"))
            continue
        parsed = pair_hex(fg_raw, bg_raw)
        if parsed is None:
            rows.append((label, color_label(fg_raw), "-", "-", "N/A"))
            continue
        fg, bg = parsed
        ratio = contrast(fg, bg)
        ok = ratio >= threshold
        rows.append((label, color_label(fg_raw), f"{ratio:.2f}", f"{threshold:.1f}", "PASS" if ok else "FAIL"))

    # Search/speech highlights choose black or white text at render time.
    for key in ("searchHit", "searchHitCurrent"):
        raw = palette.get(key)
        parsed = parse_hex(raw)
        if parsed is None:
            rows.append(("textOn" + key[0].upper() + key[1:], color_label(raw), "-", "4.5", "N/A"))
            continue
        rgb = parsed[:3]
        ratio = max(contrast((0, 0, 0), rgb), contrast((1, 1, 1), rgb))
        rows.append((
            "textOn" + key[0].upper() + key[1:], color_label(raw),
            f"{ratio:.2f}", "4.5", "PASS" if ratio >= 4.5 else "FAIL"
        ))

    for key, threshold in CODE_PAIRS:
        fg_raw = code.get(key)
        if fg_raw is None:
            rows.append(("code." + key, "MISSING", "-", "-", "SKIP"))
            continue
        parsed = pair_hex(fg_raw, code_background)
        if parsed is None:
            rows.append(("code." + key, color_label(fg_raw), "-", "-", "N/A"))
            continue
        fg, bg = parsed
        ratio = contrast(fg, bg)
        ok = ratio >= threshold
        rows.append(("code." + key, color_label(fg_raw), f"{ratio:.2f}", f"{threshold:.1f}", "PASS" if ok else "FAIL"))

    results[name] = rows


def print_results(results):
    has_fail = False
    for name, rows in results.items():
        print(f"\n== {name} ==")
        print(f"{'check':<24} {'color':<16} {'ratio':>6} {'need':>5}  status")
        print("-" * 60)
        for label, color, ratio, need, status in rows:
            print(f"{label:<24} {color:<16} {ratio:>6} {need:>5}  {status}")
            if status == "FAIL":
                has_fail = True
    return has_fail


def main():
    results = {}
    files = sorted(f for f in os.listdir(THEME_DIR) if f.endswith(".json"))
    if not files:
        print(f"No theme JSON files found in {THEME_DIR}", file=sys.stderr)
        return 2
    for fname in files:
        with open(os.path.join(THEME_DIR, fname), encoding="utf-8") as fh:
            data = json.load(fh)
        check_theme(fname, data, results)
    has_fail = print_results(results)
    return 2 if has_fail else 0


if __name__ == "__main__":
    sys.exit(main())
