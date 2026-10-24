#!/usr/bin/env python3
"""WCAG 2.x contrast check of the design-token pairs (RM-B-006).

Reads contracts/design-tokens/tokens.json -> contrast.pairs (03 §5.4.2, §5.4.3, §5.4.5,
§5.8 for palette B) and the colour tokens of the main palette (`color`, palette B).

For each pair it computes the WCAG 2.x contrast ratio
(relative luminance of sRGB, (L1 + 0.05) / (L2 + 0.05)) and:
  * status "allowed"   - must reach the threshold of its use:
                          text 4.5, large-text 3.0, non-text 3.0 -> otherwise VIOLATION;
  * status "forbidden" - a pair the design system forbids (e.g. white on `primary`);
                          reported as FORBIDDEN, never as a violation;
  * status "exception" / "decorative" / "reference" - reported, not checked;
  * "documented"        - when set, the ratio published in 03 must match the computed one
                          (rounded to 2 decimals) -> otherwise MISMATCH.
It also requires that the pair «white on primary» is present and marked forbidden
(03 §5.3 restriction 1; kernel v1.9 §24.1).

Usage:  python -I -X utf8 scripts/check_contrast.py [--tokens PATH]
Exit:   0 - no violations, mismatches or errors; 1 - otherwise; 2 - unreadable input.
Standard library only; no network.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TOKENS = ROOT / "contracts" / "design-tokens" / "tokens.json"
HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
DOC_TOLERANCE = 0.005 + 1e-9  # documented values are rounded to 2 decimals


def _linear(c8: int) -> float:
    c = c8 / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def relative_luminance(hex_color: str) -> float:
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b)


def contrast_ratio(fg: str, bg: str) -> float:
    l1, l2 = relative_luminance(fg), relative_luminance(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def resolve(ref: str, colors: dict) -> tuple[str | None, str | None]:
    """Return (hex, error)."""
    if HEX_RE.match(ref):
        return ref.upper(), None
    if ref not in colors:
        return None, f"unknown colour token '{ref}'"
    v = colors[ref]
    if not isinstance(v, str):
        return None, f"token '{ref}' is translucent; contrast needs an opaque colour"
    return v.upper(), None


def label(ref: str, hex_value: str | None) -> str:
    if HEX_RE.match(ref):
        return ref.upper()
    return f"{ref} {hex_value}" if hex_value else ref


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="WCAG 2.x contrast check of tokens.json pairs")
    ap.add_argument("--tokens", type=Path, default=DEFAULT_TOKENS)
    args = ap.parse_args(argv)
    try:
        tokens = json.loads(args.tokens.read_text(encoding="utf-8"))
        colors = tokens["color"]
        contrast = tokens["contrast"]
        thresholds = contrast["thresholds"]
        pairs = contrast["pairs"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        print(f"error: cannot read {args.tokens}: {exc}", file=sys.stderr)
        return 2

    palette = tokens.get("meta", {}).get("palette", "?")
    print(f"WCAG 2.x contrast check - palette {palette} - {args.tokens.name}")
    print(f"thresholds: text {thresholds['text']}, large-text {thresholds['large-text']}, "
          f"non-text {thresholds['non-text']}")
    print()
    print(f"{'id':<7} {'result':<10} {'ratio':>6} {'need':>5} {'doc':>6}  {'use':<10} pair")

    counts: dict[str, int] = {}
    violations: list[str] = []
    mismatches: list[str] = []
    errors: list[str] = []
    seen_ids: set[str] = set()
    seen_keys: set[tuple[str, str, str]] = set()

    for p in sorted(pairs, key=lambda x: x["id"]):
        pid, use, status = p["id"], p["use"], p["status"]
        if pid in seen_ids:
            errors.append(f"{pid}: duplicate id")
        seen_ids.add(pid)
        key = (p["fg"], p["bg"], use)
        if key in seen_keys:
            errors.append(f"{pid}: duplicate pair {key}")
        seen_keys.add(key)
        if use not in thresholds:
            errors.append(f"{pid}: unknown use '{use}'")
            continue
        fg, e1 = resolve(p["fg"], colors)
        bg, e2 = resolve(p["bg"], colors)
        if e1 or e2:
            errors.extend(f"{pid}: {e}" for e in (e1, e2) if e)
            continue
        ratio = contrast_ratio(fg, bg)
        need = float(thresholds[use])
        passes = ratio >= need
        if status == "allowed":
            result = "PASS" if passes else "VIOLATION"
            if not passes:
                violations.append(f"{pid}: {p['fg']} on {p['bg']} ({use}) {ratio:.2f} < {need}")
        elif status == "forbidden":
            result = "FORBIDDEN"
        elif status == "exception":
            result = "EXCEPTION"
        elif status == "decorative":
            result = "DECOR"
        elif status == "reference":
            result = "REFERENCE"
        else:
            errors.append(f"{pid}: unknown status '{status}'")
            continue
        counts[result] = counts.get(result, 0) + 1
        doc = p.get("documented")
        doc_s = "-" if doc is None else f"{doc:.2f}"
        if doc is not None and abs(ratio - float(doc)) > DOC_TOLERANCE:
            mismatches.append(f"{pid}: computed {ratio:.4f}, documented {doc}")
        print(f"{pid:<7} {result:<10} {ratio:>6.2f} {need:>5.1f} {doc_s:>6}  {use:<10} "
              f"{label(p['fg'], fg)} on {label(p['bg'], bg)}")

    # Required policy: «white on primary» is a forbidden pair (03 §5.3 restriction 1, §5.8).
    white_on_primary = [
        p for p in pairs
        if p["bg"] == "primary" and (p["fg"].upper() == "#FFFFFF") and p["use"] == "text"
    ]
    if not white_on_primary:
        errors.append("required pair «#FFFFFF on primary» (text) is missing")
    elif any(p["status"] != "forbidden" for p in white_on_primary):
        errors.append("pair «#FFFFFF on primary» must have status 'forbidden'")

    print()
    summary = ", ".join(f"{k} {counts[k]}" for k in sorted(counts))
    print(f"pairs: {len(pairs)} ({summary})")
    print(f"violations among allowed pairs: {len(violations)}")
    for v in violations:
        print(f"  VIOLATION {v}")
    print(f"mismatches with documented ratios: {len(mismatches)}")
    for m in mismatches:
        print(f"  MISMATCH {m}")
    print(f"errors: {len(errors)}")
    for e in errors:
        print(f"  ERROR {e}")
    ok = not (violations or mismatches or errors)
    print("RESULT: OK" if ok else "RESULT: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
