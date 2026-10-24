#!/usr/bin/env python3
"""Generate Dart design-token classes from contracts/design-tokens/tokens.json (RM-B-006).

Output: one file per class, following 03_UX_UI_DESIGN_SYSTEM.md §17.1-§17.5:
    ds_colors.dart       DsColors (ThemeExtension) - palette B is the default (kernel v1.9 §24.1)
    ds_typography.dart   DsTypography (ThemeExtension)
    ds_spacing.dart      DsSpacing (ThemeExtension)
    ds_radii.dart        DsRadii (ThemeExtension)
    ds_elevation.dart    DsElevation (ThemeExtension)
    ds_motion.dart       DsMotion (ThemeExtension)
    ds_breakpoints.dart  WindowClass, DsBreakpoints
    ds_density.dart      DsDensity, DsDensityValues

Deterministic: the same tokens.json always gives byte-identical files. Field order
comes from fixed orders in this script or from sorted keys, never from dict order
or the clock. Files are UTF-8 with LF line endings.

Usage:
    python -I -X utf8 scripts/gen_tokens_dart.py OUT_DIR [--tokens PATH] [--schema PATH]
                                                [--with-alternative-a] [--check]

    --check                 do not write; exit 1 if OUT_DIR differs from the generated output
    --with-alternative-a    also emit DsColors.lightA (alternatives.A, historical, not used in R1)

Exit codes: 0 - ok; 1 - --check found differences; 2 - invalid input or arguments.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TOKENS = ROOT / "contracts" / "design-tokens" / "tokens.json"
DEFAULT_SCHEMA = ROOT / "contracts" / "design-tokens" / "tokens.schema.json"

TEXT_ORDER = ["display", "h1", "h2", "h3", "title", "bodyLg", "body", "label", "caption", "micro"]
RADIUS_ORDER = ["xs", "sm", "md", "lg", "xl", "full"]
ELEVATION_ORDER = ["0", "1", "2", "3"]
WINDOW_ORDER = ["compact", "medium", "expanded", "large"]
DENSITY_ORDER = ["standard", "compact"]
DURATION_ORDER = ["fast", "base", "slow", "splashLogo", "mascotTransition"]
CURVE_ORDER = ["standard", "standardDecelerate", "standardAccelerate", "emphasized"]
LAYOUT_DART = [
    # (dart constant, tokens.json layout key)
    ("sidebarNarrow", "sidebarNarrow"),
    ("sidebarWide", "sidebarWide"),
    ("sidebarCollapsed", "sidebarCollapsed"),
    ("rail", "rail"),
    ("cartNarrow", "cartNarrow"),
    ("cartWide", "cartWide"),
    ("productPanel", "productPanel"),
    ("contentMaxLarge", "contentMaxLarge"),
    ("cardMinWidth", "cardMinWidth"),
]


class TokenError(Exception):
    pass


# --------------------------------------------------------------------------- helpers

def num(v) -> str:
    """Dart numeric literal, stable across runs."""
    if isinstance(v, bool):
        raise TokenError(f"boolean where number expected: {v!r}")
    if isinstance(v, int):
        return str(v)
    if float(v).is_integer():
        return str(int(v))
    return repr(float(v))


def dbl(v) -> str:
    """Dart double literal (used where a plain int literal would not be inferred as double)."""
    s = num(v)
    return s if ("." in s or "e" in s) else s + ".0"


def hex_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def dart_color(value) -> str:
    if isinstance(value, str):
        return f"Color(0xFF{value.lstrip('#').upper()})"
    r, g, b = hex_rgb(value["rgb"])
    return f"Color.fromRGBO({r}, {g}, {b}, {num(value['opacity'])})"


def color_doc(value) -> str:
    if isinstance(value, str):
        return value.upper()
    r, g, b = hex_rgb(value["rgb"])
    return f"rgba({r},{g},{b},{num(value['opacity'])})"


def header(source_hash: str, title: str) -> str:
    return (
        "// GENERATED CODE - DO NOT EDIT BY HAND.\n"
        "// Generator: scripts/gen_tokens_dart.py (RM-B-006)\n"
        f"// Source: contracts/design-tokens/tokens.json (canonical sha256 {source_hash})\n"
        f"// {title}\n"
        "// ignore_for_file: public_member_api_docs\n"
        "\n"
    )


# --------------------------------------------------------------------------- validation

def load_tokens(tokens_path: Path, schema_path: Path) -> dict:
    try:
        tokens = json.loads(tokens_path.read_text(encoding="utf-8"))
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise TokenError(f"cannot read input: {exc}") from exc
    try:
        import jsonschema  # noqa: PLC0415 - optional dependency check with clear message
    except ImportError as exc:  # pragma: no cover
        raise TokenError("python package 'jsonschema' is required (pip install jsonschema)") from exc
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(tokens), key=lambda e: list(map(str, e.absolute_path)))
    if errors:
        lines = [f"  /{'/'.join(map(str, e.absolute_path))}: {e.message}" for e in errors]
        raise TokenError("tokens.json does not match tokens.schema.json:\n" + "\n".join(lines))
    check_invariants(tokens)
    return tokens


def check_invariants(t: dict) -> None:
    problems: list[str] = []
    # Breakpoints are contiguous and ordered (03 §7.2).
    bp = t["breakpoint"]
    if bp[WINDOW_ORDER[0]]["min"] != 0:
        problems.append("breakpoint.compact.min must be 0")
    for a, b in zip(WINDOW_ORDER, WINDOW_ORDER[1:]):
        if bp[a]["maxExclusive"] != bp[b]["min"]:
            problems.append(f"breakpoint.{a}.maxExclusive must equal breakpoint.{b}.min")
    if bp[WINDOW_ORDER[-1]]["maxExclusive"] is not None:
        problems.append("breakpoint.large.maxExclusive must be null")
    # Density covers every window class exactly once (03 §8.1).
    seen: dict[str, str] = {}
    for d in DENSITY_ORDER:
        for wc in t["density"][d]["windowClasses"]:
            if wc in seen:
                problems.append(f"window class {wc} mapped to both {seen[wc]} and {d}")
            seen[wc] = d
    missing = [wc for wc in WINDOW_ORDER if wc not in seen]
    if missing:
        problems.append(f"window classes without density: {missing}")
    # Grid column bounds.
    lay = t["layout"]
    if lay["gridMinColumns"] > lay["gridMaxColumns"]:
        problems.append("layout.gridMinColumns > layout.gridMaxColumns")
    # Elevation scrim refers to an alpha colour.
    for lvl in ELEVATION_ORDER:
        scrim = t["elevation"][lvl]["scrim"]
        if scrim is not None and not isinstance(t["color"][scrim], dict):
            problems.append(f"elevation.{lvl}.scrim must refer to a translucent colour")
    if problems:
        raise TokenError("token invariants violated:\n" + "\n".join("  " + p for p in problems))


def canonical_hash(tokens: dict) -> str:
    blob = json.dumps(tokens, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- generators

def gen_colors(t: dict, h: str, with_a: bool) -> str:
    names = sorted(t["color"].keys())
    alt_a = t["alternatives"]["A"]["color"]
    if sorted(alt_a.keys()) != names:
        raise TokenError("alternatives.A.color must define exactly the same tokens as color")
    out = [header(h, "DsColors - ds.color.* (03 §5.3, §17.2); default palette B «Оранжевый», kernel v1.9 §24.1")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Colour tokens `ds.color.*`. Field names follow kernel §8.1, §17.5, §18.2 item 15.\n")
    out.append("///\n/// Palette B role rule (03 §5.9, DS-098): `primary` is a fill only, always with\n")
    out.append("/// `onPrimary`; text, prices, links and selection indicators use `primaryText`;\n")
    out.append("/// white text on `primary`, `primaryHover`, `primaryPressed` is forbidden.\n")
    out.append("@immutable\nclass DsColors extends ThemeExtension<DsColors> {\n")
    out.append("  const DsColors({\n")
    for n in names:
        out.append(f"    required this.{n},\n")
    out.append("  });\n\n")
    for n in names:
        out.append(f"  final Color {n};\n")
    out.append("\n")

    def palette(const_name: str, colors: dict, doc: str) -> None:
        out.append(f"  /// {doc}\n")
        out.append(f"  static const DsColors {const_name} = DsColors(\n")
        for n in names:
            out.append(f"    {n}: {dart_color(colors[n])}, // {color_doc(colors[n])}\n")
        out.append("  );\n\n")

    palette("lightB", t["color"], "Palette B «Оранжевый» - main R1 palette (03 §5.3; kernel v1.9 §24.1).")
    if with_a:
        palette("lightA", alt_a, "Historical alternative A+ (03 §5.2). Not used in R1.")
    out.append("  /// Default theme colours (03 §17.2): palette B.\n")
    out.append("  static const DsColors light = lightB;\n\n")
    out.append("  @override\n  DsColors copyWith({\n")
    for n in names:
        out.append(f"    Color? {n},\n")
    out.append("  }) {\n    return DsColors(\n")
    for n in names:
        out.append(f"      {n}: {n} ?? this.{n},\n")
    out.append("    );\n  }\n\n")
    out.append("  @override\n  DsColors lerp(DsColors? other, double t) {\n")
    out.append("    if (other == null) {\n      return this;\n    }\n    return DsColors(\n")
    for n in names:
        out.append(f"      {n}: Color.lerp({n}, other.{n}, t)!,\n")
    out.append("    );\n  }\n}\n")
    return "".join(out)


def gen_typography(t: dict, h: str) -> str:
    tx = t["text"]
    styles = tx["styles"]
    family = tx["fontFamily"]
    out = [header(h, "DsTypography - ds.text.* (03 §6.2, §17.3)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Text scale `ds.text.*` (font family Inter, D-17). Sizes in logical pixels.\n")
    out.append("@immutable\nclass DsTypography extends ThemeExtension<DsTypography> {\n")
    out.append("  const DsTypography({\n")
    for n in TEXT_ORDER:
        out.append(f"    required this.{n},\n")
    out.append("  });\n\n")
    for n in TEXT_ORDER:
        s = styles[n]
        out.append(
            f"  /// {s['fontSize']}/{s['lineHeight']}/{s['fontWeight']}, "
            f"letter-spacing {num(s['letterSpacing'])}; contrast class: {s['contrastClass']}.\n"
        )
        out.append(f"  final TextStyle {n};\n")
    out.append("\n  /// Tabular figures for prices, stock, quantities, codes, OTP timers (03 §6.1).\n")
    feats = ", ".join("FontFeature.tabularFigures()" for f in tx["numericFontFeatures"] if f == "tnum")
    out.append(f"  static const List<FontFeature> numeric = <FontFeature>[{feats}];\n\n")
    out.append(f"  static const String fontFamily = '{family}';\n\n")
    out.append("  /// Scale of 03 §6.2 with the Inter family.\n")
    out.append("  static const DsTypography inter = DsTypography(\n")
    for n in TEXT_ORDER:
        s = styles[n]
        out.append(f"    {n}: TextStyle(\n")
        out.append("      fontFamily: fontFamily,\n")
        out.append(f"      fontSize: {num(s['fontSize'])},\n")
        out.append(f"      height: {num(s['lineHeight'])} / {num(s['fontSize'])},\n")
        out.append(f"      fontWeight: FontWeight.w{s['fontWeight']},\n")
        out.append(f"      letterSpacing: {num(s['letterSpacing'])},\n")
        out.append("    ),\n")
    out.append("  );\n\n")
    for n in TEXT_ORDER:
        s = styles[n]
        if "fontWeightMedium" in s:
            out.append(f"  /// `{n}` with weight {s['fontWeightMedium']}.\n")
            out.append(
                f"  TextStyle get {n}Medium => {n}.copyWith(fontWeight: FontWeight.w{s['fontWeightMedium']});\n\n"
            )
    price = tx["price"]
    out.append(f"  /// Price: {price['base']}/{price['fontWeight']} + tabular figures.\n")
    out.append(f"  TextStyle get price => priceOf({price['base']});\n\n")
    out.append("  /// Any scale step as a price: weight and tabular figures (03 §6.2 rules).\n")
    out.append("  TextStyle priceOf(TextStyle base) =>\n")
    out.append(f"      base.copyWith(fontWeight: FontWeight.w{price['fontWeight']}, fontFeatures: numeric);\n\n")
    out.append("  @override\n  DsTypography copyWith({\n")
    for n in TEXT_ORDER:
        out.append(f"    TextStyle? {n},\n")
    out.append("  }) {\n    return DsTypography(\n")
    for n in TEXT_ORDER:
        out.append(f"      {n}: {n} ?? this.{n},\n")
    out.append("    );\n  }\n\n")
    out.append("  @override\n  DsTypography lerp(DsTypography? other, double t) {\n")
    out.append("    if (other == null) {\n      return this;\n    }\n    return DsTypography(\n")
    for n in TEXT_ORDER:
        out.append(f"      {n}: TextStyle.lerp({n}, other.{n}, t)!,\n")
    out.append("    );\n  }\n}\n")
    return "".join(out)


def gen_spacing(t: dict, h: str) -> str:
    keys = sorted(t["space"].keys(), key=int)
    bp = t["breakpoint"]
    out = [header(h, "DsSpacing - ds.space.1..10 (03 §7.1, §17.4)")]
    out.append("import 'dart:ui' show lerpDouble;\n\n")
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Spacing `ds.space.1` ... `ds.space.10` (4 lp module, 03 §7.1).\n")
    out.append("@immutable\nclass DsSpacing extends ThemeExtension<DsSpacing> {\n")
    out.append("  const DsSpacing({\n")
    for k in keys:
        out.append(f"    required this.s{k},\n")
    out.append("  });\n\n")
    for k in keys:
        out.append(f"  /// `ds.space.{k}` = {t['space'][k]} lp.\n  final double s{k};\n")
    out.append("\n  static const DsSpacing defaults = DsSpacing(\n")
    for k in keys:
        out.append(f"    s{k}: {num(t['space'][k])},\n")
    out.append("  );\n\n")
    pages = [("Compact", "compact"), ("Medium", "medium"), ("Large", "large")]
    for suffix, wc in pages:
        out.append(f"  /// Side margins of window class `{wc}` (03 §7.2).\n")
        out.append(
            f"  EdgeInsets get pagePadding{suffix} => "
            f"const EdgeInsets.symmetric(horizontal: {num(bp[wc]['pageMargin'])});\n\n"
        )
    out.append("  @override\n  DsSpacing copyWith({\n")
    for k in keys:
        out.append(f"    double? s{k},\n")
    out.append("  }) {\n    return DsSpacing(\n")
    for k in keys:
        out.append(f"      s{k}: s{k} ?? this.s{k},\n")
    out.append("    );\n  }\n\n")
    out.append("  @override\n  DsSpacing lerp(DsSpacing? other, double t) {\n")
    out.append("    if (other == null) {\n      return this;\n    }\n    return DsSpacing(\n")
    for k in keys:
        out.append(f"      s{k}: lerpDouble(s{k}, other.s{k}, t)!,\n")
    out.append("    );\n  }\n}\n")
    return "".join(out)


def gen_radii(t: dict, h: str) -> str:
    r = t["radius"]
    out = [header(h, "DsRadii - ds.radius.{xs,sm,md,lg,xl,full} (03 §7.5, §17.4)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Corner radii `ds.radius.*`. `xl` - only the form card of SCR-01...SCR-04 and SCR-08\n")
    out.append("/// (kernel §18.2 item 15); SCR-06, SCR-07 use `lg`.\n")
    out.append("@immutable\nclass DsRadii extends ThemeExtension<DsRadii> {\n")
    out.append("  const DsRadii({\n")
    for k in RADIUS_ORDER:
        out.append(f"    required this.{k},\n")
    out.append("  });\n\n")
    for k in RADIUS_ORDER:
        out.append(f"  /// `ds.radius.{k}` = {r[k]} lp.\n  final Radius {k};\n")
    out.append("\n  static const DsRadii defaults = DsRadii(\n")
    for k in RADIUS_ORDER:
        out.append(f"    {k}: Radius.circular({num(r[k])}),\n")
    out.append("  );\n\n")
    out.append("  /// Card corners (`md`).\n  BorderRadius get card => BorderRadius.all(md);\n\n")
    out.append("  /// Bottom sheet top corners (`lg`).\n  BorderRadius get sheetTop => BorderRadius.vertical(top: lg);\n\n")
    out.append("  @override\n  DsRadii copyWith({\n")
    for k in RADIUS_ORDER:
        out.append(f"    Radius? {k},\n")
    out.append("  }) {\n    return DsRadii(\n")
    for k in RADIUS_ORDER:
        out.append(f"      {k}: {k} ?? this.{k},\n")
    out.append("    );\n  }\n\n")
    out.append("  @override\n  DsRadii lerp(DsRadii? other, double t) {\n")
    out.append("    if (other == null) {\n      return this;\n    }\n    return DsRadii(\n")
    for k in RADIUS_ORDER:
        out.append(f"      {k}: Radius.lerp({k}, other.{k}, t)!,\n")
    out.append("    );\n  }\n}\n")
    return "".join(out)


def gen_elevation(t: dict, h: str) -> str:
    el = t["elevation"]
    scrims = sorted({el[k]["scrim"] for k in ELEVATION_ORDER if el[k]["scrim"]})
    overlay_token = scrims[0] if scrims else "overlay"
    out = [header(h, "DsElevation - ds.elevation.0..3 (03 §7.6, §17.4; kernel §8.3)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Shadows `ds.elevation.*` (kernel §8.3 has priority over R4 §5.4, kernel §17.5).\n")
    out.append("@immutable\nclass DsElevation extends ThemeExtension<DsElevation> {\n")
    out.append("  const DsElevation({\n")
    for k in ELEVATION_ORDER:
        out.append(f"    required this.e{k},\n")
    out.append("    required this.overlay,\n  });\n\n")
    for k in ELEVATION_ORDER:
        lvl = el[k]
        extras = []
        if lvl["borderColor"]:
            extras.append(f"border `{lvl['borderColor']}` {num(lvl['borderWidth'])} px")
        if lvl["scrim"]:
            extras.append(f"`{lvl['scrim']}` scrim under the element")
        desc = "; ".join(extras) if extras else "no border"
        out.append(f"  /// `ds.elevation.{k}`: {len(lvl['shadows'])} shadow(s); {desc}.\n")
        out.append(f"  final List<BoxShadow> e{k};\n")
    out.append(f"\n  /// Scrim colour (= `DsColors.{overlay_token}`).\n  final Color overlay;\n\n")
    out.append("  static const DsElevation defaults = DsElevation(\n")
    for k in ELEVATION_ORDER:
        shadows = el[k]["shadows"]
        if not shadows:
            out.append(f"    e{k}: <BoxShadow>[],\n")
            continue
        out.append(f"    e{k}: <BoxShadow>[\n")
        for s in shadows:
            out.append("      BoxShadow(\n")
            out.append(f"        color: {dart_color(s['color'])},\n")
            out.append(f"        offset: Offset({num(s['x'])}, {num(s['y'])}),\n")
            out.append(f"        blurRadius: {num(s['blur'])},\n")
            out.append(f"        spreadRadius: {num(s['spread'])},\n")
            out.append("      ),\n")
        out.append("    ],\n")
    out.append(f"    overlay: {dart_color(t['color'][overlay_token])},\n  );\n\n")
    out.append("  @override\n  DsElevation copyWith({\n")
    for k in ELEVATION_ORDER:
        out.append(f"    List<BoxShadow>? e{k},\n")
    out.append("    Color? overlay,\n  }) {\n    return DsElevation(\n")
    for k in ELEVATION_ORDER:
        out.append(f"      e{k}: e{k} ?? this.e{k},\n")
    out.append("      overlay: overlay ?? this.overlay,\n    );\n  }\n\n")
    out.append("  @override\n  DsElevation lerp(DsElevation? other, double t) {\n")
    out.append("    if (other == null) {\n      return this;\n    }\n    return DsElevation(\n")
    for k in ELEVATION_ORDER:
        out.append(f"      e{k}: BoxShadow.lerpList(e{k}, other.e{k}, t)!,\n")
    out.append("      overlay: Color.lerp(overlay, other.overlay, t)!,\n    );\n  }\n}\n")
    return "".join(out)


def gen_motion(t: dict, h: str) -> str:
    d = t["motion"]["duration"]
    c = t["motion"]["curve"]
    out = [header(h, "DsMotion - ds.motion.* (03 §11.1, §17.5; kernel §8.4, §17.5)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Durations and curves `ds.motion.*`. Widgets take durations through [of].\n")
    out.append("@immutable\nclass DsMotion extends ThemeExtension<DsMotion> {\n")
    out.append("  const DsMotion({\n")
    for k in DURATION_ORDER:
        out.append(f"    required this.{k},\n")
    for k in CURVE_ORDER:
        out.append(f"    required this.{k},\n")
    out.append("    required this.reduceMotion,\n  });\n\n")
    for k in DURATION_ORDER:
        out.append(f"  /// `ds.motion.{k}` = {d[k]} ms.\n  final Duration {k};\n")
    for k in CURVE_ORDER:
        p = ", ".join(num(x) for x in c[k])
        out.append(f"  /// `ds.motion.curve.{k}` = Cubic({p}).\n  final Curve {k};\n")
    out.append("\n  /// disableAnimations || OS reduce motion || SCR-42 setting (03 §11.1).\n")
    out.append("  final bool reduceMotion;\n\n")
    out.append("  static const DsMotion defaults = DsMotion(\n")
    for k in DURATION_ORDER:
        out.append(f"    {k}: Duration(milliseconds: {d[k]}),\n")
    for k in CURVE_ORDER:
        p = ", ".join(num(x) for x in c[k])
        out.append(f"    {k}: Cubic({p}),\n")
    out.append("    reduceMotion: false,\n  );\n\n")
    out.append("  /// The only non-zero duration allowed under reduce motion (kernel §17.5).\n")
    out.append(f"  Duration get reducedCrossfade => const Duration(milliseconds: {d['reducedCrossfade']});\n\n")
    out.append("  /// Duration to use: zero when [reduceMotion] is on.\n")
    out.append("  Duration of(Duration d) => reduceMotion ? Duration.zero : d;\n\n")
    out.append("  /// Builds the motion tokens for [context] with the three reduce-motion sources.\n")
    out.append("  static DsMotion resolve(BuildContext context, {required bool userReduceMotion}) {\n")
    out.append("    final bool reduce = MediaQuery.disableAnimationsOf(context) ||\n")
    out.append("        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion ||\n")
    out.append("        userReduceMotion;\n")
    out.append("    return defaults.copyWith(reduceMotion: reduce);\n  }\n\n")
    out.append("  @override\n  DsMotion copyWith({\n")
    for k in DURATION_ORDER:
        out.append(f"    Duration? {k},\n")
    for k in CURVE_ORDER:
        out.append(f"    Curve? {k},\n")
    out.append("    bool? reduceMotion,\n  }) {\n    return DsMotion(\n")
    for k in DURATION_ORDER + CURVE_ORDER:
        out.append(f"      {k}: {k} ?? this.{k},\n")
    out.append("      reduceMotion: reduceMotion ?? this.reduceMotion,\n    );\n  }\n\n")
    out.append("  @override\n  DsMotion lerp(DsMotion? other, double t) {\n")
    out.append("    if (other == null) {\n      return this;\n    }\n")
    out.append("    return t < 0.5 ? this : other;\n  }\n}\n")
    return "".join(out)


def gen_breakpoints(t: dict, h: str) -> str:
    bp = t["breakpoint"]
    lay = t["layout"]
    out = [header(h, "DsBreakpoints - ds.breakpoint.* (03 §7.2, §7.3, §8.4, §17.4; kernel §17.5)")]
    out.append("import 'dart:math' as math;\n\n")
    out.append("import 'package:flutter/widgets.dart';\n\n")
    out.append("/// Window classes (03 §7.2).\n")
    out.append("enum WindowClass { " + ", ".join(WINDOW_ORDER) + " }\n\n")
    out.append("/// Breakpoints and layout sizes in logical pixels.\nclass DsBreakpoints {\n")
    out.append("  DsBreakpoints._();\n\n")
    for wc in WINDOW_ORDER[1:]:
        lo = bp[wc]["min"]
        hi = bp[wc]["maxExclusive"]
        rng = f"{lo}-{hi - 1}" if hi is not None else f">= {lo}"
        out.append(f"  /// `ds.breakpoint.{wc}`: {rng} lp.\n")
        out.append(f"  static const double {wc} = {num(lo)};\n")
    out.append("\n")
    for dart_name, key in LAYOUT_DART:
        out.append(f"  static const double {dart_name} = {num(lay[key])};\n")
    out.append(f"  static const int gridMinColumns = {lay['gridMinColumns']};\n")
    out.append(f"  static const int gridMaxColumns = {lay['gridMaxColumns']};\n\n")
    out.append("  /// Window class by `MediaQuery.sizeOf(context).width`.\n")
    out.append("  static WindowClass of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);\n\n")
    out.append("  /// Window class for a window width.\n")
    out.append("  static WindowClass forWidth(double width) {\n")
    for wc in reversed(WINDOW_ORDER[1:]):
        out.append(f"    if (width >= {wc}) {{\n      return WindowClass.{wc};\n    }}\n")
    out.append(f"    return WindowClass.{WINDOW_ORDER[0]};\n  }}\n\n")
    out.append("  /// Card grid columns (03 §7.3): max(2, min(6, floor((W + gap) / (160 + gap)))).\n")
    out.append("  /// [contentWidth] is the content zone WITHOUT side margins (on `large` - at most\n")
    out.append("  /// [contentMaxLarge], applied by the caller).\n")
    out.append("  static int gridColumns(double contentWidth, double gap) {\n")
    out.append("    final int n = ((contentWidth + gap) / (cardMinWidth + gap)).floor();\n")
    out.append("    return math.max(gridMinColumns, math.min(gridMaxColumns, n));\n  }\n}\n")
    return "".join(out)


def gen_density(t: dict, h: str) -> str:
    den = t["density"]
    props = [
        ("rowHeight", "list row height"),
        ("rowHeightWithThumb", "list row height with thumbnail"),
        ("cardPadding", "card padding"),
        ("rowIconSize", "icon size in a row"),
        ("gridGap", "card grid gap (03 §7.3)"),
    ]
    out = [header(h, "DsDensity (03 §8.1, §17.4; kernel §17.5)")]
    out.append("import 'ds_breakpoints.dart';\n\n")
    out.append("/// Density (03 §8.1). Never lowers a touch target below 44/48 lp.\n")
    out.append("enum DsDensity { " + ", ".join(DENSITY_ORDER) + " }\n\n")
    out.append("/// Values of each density.\nextension DsDensityValues on DsDensity {\n")
    for p, doc in props:
        vals = " / ".join(num(den[d][p]) for d in DENSITY_ORDER)
        out.append(f"  /// {doc}: {vals}.\n")
        out.append(f"  double get {p} => switch (this) {{\n")
        for d in DENSITY_ORDER:
            out.append(f"        DsDensity.{d} => {dbl(den[d][p])},\n")
        out.append("      };\n\n")
    out.append("  /// compact/medium -> standard; expanded/large -> compact.\n")
    out.append("  static DsDensity forWindowClass(WindowClass c) => switch (c) {\n")
    for wc in WINDOW_ORDER:
        d = next(d for d in DENSITY_ORDER if wc in den[d]["windowClasses"])
        out.append(f"        WindowClass.{wc} => DsDensity.{d},\n")
    out.append("      };\n}\n")
    return "".join(out)


def generate(tokens: dict, with_a: bool) -> dict[str, str]:
    h = canonical_hash(tokens)
    files = {
        "ds_colors.dart": gen_colors(tokens, h, with_a),
        "ds_typography.dart": gen_typography(tokens, h),
        "ds_spacing.dart": gen_spacing(tokens, h),
        "ds_radii.dart": gen_radii(tokens, h),
        "ds_elevation.dart": gen_elevation(tokens, h),
        "ds_motion.dart": gen_motion(tokens, h),
        "ds_breakpoints.dart": gen_breakpoints(tokens, h),
        "ds_density.dart": gen_density(tokens, h),
    }
    return dict(sorted(files.items()))


# --------------------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out_dir", type=Path, help="output directory (e.g. pos-app/lib/design_system/tokens)")
    ap.add_argument("--tokens", type=Path, default=DEFAULT_TOKENS)
    ap.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    ap.add_argument("--with-alternative-a", action="store_true",
                    help="also emit DsColors.lightA from alternatives.A (historical, not used in R1)")
    ap.add_argument("--check", action="store_true", help="compare instead of writing; exit 1 on differences")
    args = ap.parse_args(argv)

    try:
        tokens = load_tokens(args.tokens, args.schema)
        files = generate(tokens, args.with_alternative_a)
    except TokenError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.check:
        diffs = []
        for name, content in files.items():
            p = args.out_dir / name
            if not p.is_file() or p.read_bytes() != content.encode("utf-8"):
                diffs.append(name)
        for name in diffs:
            print(f"differs: {args.out_dir / name}")
        print(f"checked {len(files)} files, {len(diffs)} differ")
        return 1 if diffs else 0

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (args.out_dir / name).write_bytes(content.encode("utf-8"))
        print(f"wrote {args.out_dir / name}")
    print(f"generated {len(files)} files (palette {tokens['meta']['palette']}, sha256 {canonical_hash(tokens)[:12]})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
