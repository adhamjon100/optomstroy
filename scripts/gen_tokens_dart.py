#!/usr/bin/env python3
"""Generate Dart design-token classes from contracts/design-tokens/tokens.json (RM-B-006).

Output: one file per class, following 03_UX_UI_DESIGN_SYSTEM.md §17.1-§17.5:
    ds_colors.dart       DsColors (ThemeExtension) - palette B is the default (kernel v1.9 §24.1; values ADR-111)
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

Formatted: the files are already in the `dart format` form (tall style, page width 120 of
pos-app/analysis_options.yaml; see "dart format layout" below), so formatting pos-app leaves
them unchanged and `--check` against pos-app/lib/design_system/tokens stays at 0 differences.
The layout is computed here, without the Dart SDK, so the output does not depend on the machine.

Usage:
    python -I -X utf8 scripts/gen_tokens_dart.py OUT_DIR [--tokens PATH] [--schema PATH]
                                                [--with-alternative-a] [--check]

    --check                 do not write; exit 1 if OUT_DIR differs from the generated output
    --with-alternative-a    also emit DsColors.lightA (alternatives.A, historical, not used in R1)

Every alternative must define exactly the colour tokens of `color`. Alternatives with status
"rollback" (alternatives.B_2026_10_21 - palette B before ADR-111) are ALWAYS emitted, without a
flag, so `make gen` and `--check` give the same output everywhere:
B_2026_10_21 -> DsColors.lightB20261021 (lowerCamelCase because of lint constant_identifier_names).

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
    ("topBarHeight", "topBarHeight"),
    ("navDrawer", "navDrawer"),
    ("cartDrawer", "cartDrawer"),
    ("catalogColumn", "catalogColumn"),
    ("catalogCardMinWidth", "catalogCardMinWidth"),
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


# --------------------------------------------------------------------------- dart format layout
#
# The output is already in the form `dart format` gives it (tall style, Dart >= 3.7; page width of
# pos-app/analysis_options.yaml), so `dart format` leaves lib/design_system/tokens unchanged and
# `--check` stays green after anyone formats pos-app. Only the shapes this generator emits are covered:
# a bracketed list is written on one line when it fits PAGE_WIDTH, otherwise one item per line with a
# trailing comma (nested lists are decided the same way on their own line); a documented class member
# is separated from the previous member by a blank line; a switch expression always splits its cases.

PAGE_WIDTH = 120  # pos-app/analysis_options.yaml: formatter.page_width


class Seq:
    """Bracketed Dart list: `head` ends with the opening bracket, `tail` starts with the closing one.

    Items are strings or nested Seq. Example: Seq("return DsRadii(", ["xs: xs ?? this.xs"], ");").
    """

    __slots__ = ("head", "items", "tail")

    def __init__(self, head: str, items: list, tail: str) -> None:
        self.head = head
        self.items = items
        self.tail = tail

    def flat(self) -> str:
        return self.head + ", ".join(flat(i) for i in self.items) + self.tail


def flat(x) -> str:
    return x if isinstance(x, str) else x.flat()


def fmt(x, indent: int, suffix: str = "") -> str:
    """Lines of `x` at `indent` spaces, followed by `suffix` (e.g. "," for a list item)."""
    pad = " " * indent
    line = pad + flat(x) + suffix
    if isinstance(x, str) or not x.items or len(line) <= PAGE_WIDTH:
        return line + "\n"
    body = "".join(fmt(i, indent + 2, ",") for i in x.items)
    return f"{pad}{x.head}\n{body}{pad}{x.tail}{suffix}\n"


def documented(members: list[str]) -> str:
    """Documented class members (each `/// doc` + declaration) with a blank line between them."""
    return "\n".join(members)


def copy_with(cls: str, fields: list[tuple[str, str]]) -> str:
    """`@override copyWith` for [(type, name)] fields."""
    return (
        "  @override\n"
        + fmt(Seq(f"{cls} copyWith({{", [f"{typ}? {n}" for typ, n in fields], "}) {"), 2)
        + fmt(Seq(f"return {cls}(", [f"{n}: {n} ?? this.{n}" for _, n in fields], ");"), 4)
        + "  }\n\n"
    )


def lerp(cls: str, items: list[str]) -> str:
    """`@override lerp` whose constructor arguments are [items]; the last member, it also closes the class."""
    return (
        f"  @override\n  {cls} lerp({cls}? other, double t) {{\n"
        "    if (other == null) {\n      return this;\n    }\n"
        + fmt(Seq(f"return {cls}(", items, ");"), 4)
        + "  }\n}\n"
    )


# --------------------------------------------------------------------------- generators

def rollback_const_name(key: str) -> str:
    """alternatives key -> Dart constant name: B_2026_10_21 -> lightB20261021 (lowerCamelCase)."""
    return "light" + key.replace("_", "")


def gen_colors(t: dict, h: str, with_a: bool) -> str:
    names = sorted(t["color"].keys())
    alts = t["alternatives"]
    for key in sorted(alts):
        if sorted(alts[key]["color"].keys()) != names:
            raise TokenError(f"alternatives.{key}.color must define exactly the same tokens as color")
    alt_a = alts["A"]["color"]
    rollbacks = sorted(k for k in alts if alts[k]["status"] == "rollback")
    out = [header(h, "DsColors - ds.color.* (03 §5.3, §17.2); default palette B «Оранжевый», "
                     "kernel v1.9 §24.1, ADR-111")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Colour tokens `ds.color.*`. Field names follow kernel §8.1, §17.5, §18.2 item 15.\n")
    out.append("///\n/// Palette B role rule (03 §5.9, DS-098): `primary` is a fill only, always with\n")
    out.append("/// `onPrimary`; text, prices, links and selection indicators use `primaryText`.\n")
    out.append("/// ADR-111: white `onPrimary` on `primary` #D9380F is 4.64:1 (AA); white text is forbidden\n")
    out.append("/// only on orange fills below 4.5:1, e.g. `brandAccent` #FF8700 (2.41:1).\n")
    out.append("@immutable\nclass DsColors extends ThemeExtension<DsColors> {\n")
    out.append(fmt(Seq("const DsColors({", [f"required this.{n}" for n in names], "});"), 2))
    out.append("\n")
    for n in names:
        out.append(f"  final Color {n};\n")
    out.append("\n")

    def palette(const_name: str, colors: dict, doc: str) -> None:
        # A trailing line comment on every item: `dart format` always keeps one item per line here.
        out.append(f"  /// {doc}\n")
        out.append(f"  static const DsColors {const_name} = DsColors(\n")
        for n in names:
            out.append(f"    {n}: {dart_color(colors[n])}, // {color_doc(colors[n])}\n")
        out.append("  );\n\n")

    palette("lightB", t["color"],
            "Palette B «Оранжевый» - main R1 palette (03 §5.3; kernel v1.9 §24.1; values ADR-111).")
    for key in rollbacks:
        palette(rollback_const_name(key), alts[key]["color"],
                f"Rollback alternatives.{key} ({alts[key]['name']}): AppTheme.light(colors: ...).")
    if with_a:
        palette("lightA", alt_a, "Historical alternative A+ (03 §5.2). Not used in R1.")
    out.append("  /// Default theme colours (03 §17.2): palette B.\n")
    out.append("  static const DsColors light = lightB;\n\n")
    out.append(copy_with("DsColors", [("Color", n) for n in names]))
    out.append(lerp("DsColors", [f"{n}: Color.lerp({n}, other.{n}, t)!" for n in names]))
    return "".join(out)


def gen_typography(t: dict, h: str) -> str:
    tx = t["text"]
    styles = tx["styles"]
    family = tx["fontFamily"]
    out = [header(h, "DsTypography - ds.text.* (03 §6.2, §17.3)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Text scale `ds.text.*` (font family Inter, D-17). Sizes in logical pixels.\n")
    out.append("@immutable\nclass DsTypography extends ThemeExtension<DsTypography> {\n")
    out.append(fmt(Seq("const DsTypography({", [f"required this.{n}" for n in TEXT_ORDER], "});"), 2))
    out.append("\n")
    fields = []
    for n in TEXT_ORDER:
        s = styles[n]
        fields.append(
            f"  /// {s['fontSize']}/{s['lineHeight']}/{s['fontWeight']}, "
            f"letter-spacing {num(s['letterSpacing'])}; contrast class: {s['contrastClass']}.\n"
            f"  final TextStyle {n};\n"
        )
    out.append(documented(fields))
    out.append("\n  /// Tabular figures for prices, stock, quantities, codes, OTP timers (03 §6.1).\n")
    feats = ["FontFeature.tabularFigures()" for f in tx["numericFontFeatures"] if f == "tnum"]
    out.append(fmt(Seq("static const List<FontFeature> numeric = <FontFeature>[", feats, "];"), 2))
    out.append("\n")
    out.append(f"  static const String fontFamily = '{family}';\n\n")
    out.append("  /// Scale of 03 §6.2 with the Inter family.\n")
    scale = []
    for n in TEXT_ORDER:
        s = styles[n]
        scale.append(Seq(f"{n}: TextStyle(", [
            "fontFamily: fontFamily",
            f"fontSize: {num(s['fontSize'])}",
            f"height: {num(s['lineHeight'])} / {num(s['fontSize'])}",
            f"fontWeight: FontWeight.w{s['fontWeight']}",
            f"letterSpacing: {num(s['letterSpacing'])}",
        ], ")"))
    out.append(fmt(Seq("static const DsTypography inter = DsTypography(", scale, ");"), 2))
    out.append("\n")
    for n in TEXT_ORDER:
        s = styles[n]
        if "fontWeightMedium" in s:
            out.append(f"  /// `{n}` with weight {s['fontWeightMedium']}.\n")
            out.append(fmt(Seq(f"TextStyle get {n}Medium => {n}.copyWith(",
                               [f"fontWeight: FontWeight.w{s['fontWeightMedium']}"], ");"), 2))
            out.append("\n")
    price = tx["price"]
    out.append(f"  /// Price: {price['base']}/{price['fontWeight']} + tabular figures.\n")
    out.append(f"  TextStyle get price => priceOf({price['base']});\n\n")
    out.append("  /// Any scale step as a price: weight and tabular figures (03 §6.2 rules).\n")
    out.append(fmt(Seq("TextStyle priceOf(TextStyle base) => base.copyWith(",
                       [f"fontWeight: FontWeight.w{price['fontWeight']}", "fontFeatures: numeric"], ");"), 2))
    out.append("\n")
    out.append(copy_with("DsTypography", [("TextStyle", n) for n in TEXT_ORDER]))
    out.append(lerp("DsTypography", [f"{n}: TextStyle.lerp({n}, other.{n}, t)!" for n in TEXT_ORDER]))
    return "".join(out)


def gen_spacing(t: dict, h: str) -> str:
    keys = sorted(t["space"].keys(), key=int)
    bp = t["breakpoint"]
    out = [header(h, "DsSpacing - ds.space.1..10 (03 §7.1, §17.4)")]
    out.append("import 'dart:ui' show lerpDouble;\n\n")
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Spacing `ds.space.1` ... `ds.space.10` (4 lp module, 03 §7.1).\n")
    out.append("@immutable\nclass DsSpacing extends ThemeExtension<DsSpacing> {\n")
    out.append(fmt(Seq("const DsSpacing({", [f"required this.s{k}" for k in keys], "});"), 2))
    out.append("\n")
    out.append(documented([f"  /// `ds.space.{k}` = {t['space'][k]} lp.\n  final double s{k};\n" for k in keys]))
    out.append("\n")
    out.append(fmt(Seq("static const DsSpacing defaults = DsSpacing(",
                       [f"s{k}: {num(t['space'][k])}" for k in keys], ");"), 2))
    out.append("\n")
    pages = [("Compact", "compact"), ("Medium", "medium"), ("Large", "large")]
    for suffix, wc in pages:
        out.append(f"  /// Side margins of window class `{wc}` (03 §7.2).\n")
        out.append(fmt(Seq(f"EdgeInsets get pagePadding{suffix} => const EdgeInsets.symmetric(",
                           [f"horizontal: {num(bp[wc]['pageMargin'])}"], ");"), 2))
        out.append("\n")
    out.append(copy_with("DsSpacing", [("double", f"s{k}") for k in keys]))
    out.append(lerp("DsSpacing", [f"s{k}: lerpDouble(s{k}, other.s{k}, t)!" for k in keys]))
    return "".join(out)


def gen_radii(t: dict, h: str) -> str:
    r = t["radius"]
    out = [header(h, "DsRadii - ds.radius.{xs,sm,md,lg,xl,full} (03 §7.5, §17.4)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Corner radii `ds.radius.*`. `xl` - only the form card of SCR-01...SCR-04 and SCR-08\n")
    out.append("/// (kernel §18.2 item 15); SCR-06, SCR-07 use `lg`.\n")
    out.append("@immutable\nclass DsRadii extends ThemeExtension<DsRadii> {\n")
    out.append(fmt(Seq("const DsRadii({", [f"required this.{k}" for k in RADIUS_ORDER], "});"), 2))
    out.append("\n")
    out.append(documented([f"  /// `ds.radius.{k}` = {r[k]} lp.\n  final Radius {k};\n" for k in RADIUS_ORDER]))
    out.append("\n")
    out.append(fmt(Seq("static const DsRadii defaults = DsRadii(",
                       [f"{k}: Radius.circular({num(r[k])})" for k in RADIUS_ORDER], ");"), 2))
    out.append("\n")
    out.append("  /// Card corners (`md`).\n  BorderRadius get card => BorderRadius.all(md);\n\n")
    out.append("  /// Bottom sheet top corners (`lg`).\n  BorderRadius get sheetTop => BorderRadius.vertical(top: lg);\n\n")
    out.append(copy_with("DsRadii", [("Radius", k) for k in RADIUS_ORDER]))
    out.append(lerp("DsRadii", [f"{k}: Radius.lerp({k}, other.{k}, t)!" for k in RADIUS_ORDER]))
    return "".join(out)


def gen_elevation(t: dict, h: str) -> str:
    el = t["elevation"]
    scrims = sorted({el[k]["scrim"] for k in ELEVATION_ORDER if el[k]["scrim"]})
    overlay_token = scrims[0] if scrims else "overlay"
    out = [header(h, "DsElevation - ds.elevation.0..3 (03 §7.6, §17.4; kernel §8.3)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Shadows `ds.elevation.*` (kernel §8.3 has priority over R4 §5.4, kernel §17.5).\n")
    out.append("@immutable\nclass DsElevation extends ThemeExtension<DsElevation> {\n")
    out.append(fmt(Seq("const DsElevation({",
                       [f"required this.e{k}" for k in ELEVATION_ORDER] + ["required this.overlay"], "});"), 2))
    out.append("\n")
    fields = []
    for k in ELEVATION_ORDER:
        lvl = el[k]
        extras = []
        if lvl["borderColor"]:
            extras.append(f"border `{lvl['borderColor']}` {num(lvl['borderWidth'])} px")
        if lvl["scrim"]:
            extras.append(f"`{lvl['scrim']}` scrim under the element")
        desc = "; ".join(extras) if extras else "no border"
        fields.append(f"  /// `ds.elevation.{k}`: {len(lvl['shadows'])} shadow(s); {desc}.\n"
                      f"  final List<BoxShadow> e{k};\n")
    fields.append(f"  /// Scrim colour (= `DsColors.{overlay_token}`).\n  final Color overlay;\n")
    out.append(documented(fields))
    out.append("\n")
    levels: list = []
    for k in ELEVATION_ORDER:
        shadows = [
            Seq("BoxShadow(", [
                f"color: {dart_color(s['color'])}",
                f"offset: Offset({num(s['x'])}, {num(s['y'])})",
                f"blurRadius: {num(s['blur'])}",
                f"spreadRadius: {num(s['spread'])}",
            ], ")")
            for s in el[k]["shadows"]
        ]
        levels.append(Seq(f"e{k}: <BoxShadow>[", shadows, "]"))
    levels.append(f"overlay: {dart_color(t['color'][overlay_token])}")
    out.append(fmt(Seq("static const DsElevation defaults = DsElevation(", levels, ");"), 2))
    out.append("\n")
    out.append(copy_with("DsElevation", [("List<BoxShadow>", f"e{k}") for k in ELEVATION_ORDER]
                         + [("Color", "overlay")]))
    out.append(lerp("DsElevation", [f"e{k}: BoxShadow.lerpList(e{k}, other.e{k}, t)!" for k in ELEVATION_ORDER]
                    + ["overlay: Color.lerp(overlay, other.overlay, t)!"]))
    return "".join(out)


def gen_motion(t: dict, h: str) -> str:
    d = t["motion"]["duration"]
    c = t["motion"]["curve"]
    out = [header(h, "DsMotion - ds.motion.* (03 §11.1, §17.5; kernel §8.4, §17.5)")]
    out.append("import 'package:flutter/material.dart';\n\n")
    out.append("/// Durations and curves `ds.motion.*`. Widgets take durations through [of].\n")
    out.append("@immutable\nclass DsMotion extends ThemeExtension<DsMotion> {\n")
    out.append(fmt(Seq("const DsMotion({", [f"required this.{k}" for k in DURATION_ORDER + CURVE_ORDER]
                       + ["required this.reduceMotion"], "});"), 2))
    out.append("\n")
    fields = [f"  /// `ds.motion.{k}` = {d[k]} ms.\n  final Duration {k};\n" for k in DURATION_ORDER]
    for k in CURVE_ORDER:
        p = ", ".join(num(x) for x in c[k])
        fields.append(f"  /// `ds.motion.curve.{k}` = Cubic({p}).\n  final Curve {k};\n")
    fields.append("  /// disableAnimations || OS reduce motion || SCR-42 setting (03 §11.1).\n"
                  "  final bool reduceMotion;\n")
    out.append(documented(fields))
    out.append("\n")
    values = [f"{k}: Duration(milliseconds: {d[k]})" for k in DURATION_ORDER]
    values += [f"{k}: Cubic({', '.join(num(x) for x in c[k])})" for k in CURVE_ORDER]
    values.append("reduceMotion: false")
    out.append(fmt(Seq("static const DsMotion defaults = DsMotion(", values, ");"), 2))
    out.append("\n")
    out.append("  /// The only non-zero duration allowed under reduce motion (kernel §17.5).\n")
    out.append(f"  Duration get reducedCrossfade => const Duration(milliseconds: {d['reducedCrossfade']});\n\n")
    out.append("  /// Duration to use: zero when [reduceMotion] is on.\n")
    out.append("  Duration of(Duration d) => reduceMotion ? Duration.zero : d;\n\n")
    out.append("  /// Builds the motion tokens for [context] with the three reduce-motion sources.\n")
    out.append("  static DsMotion resolve(BuildContext context, {required bool userReduceMotion}) {\n")
    out.append("    final bool reduce =\n")
    out.append("        MediaQuery.disableAnimationsOf(context) ||\n")
    out.append("        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion ||\n")
    out.append("        userReduceMotion;\n")
    out.append("    return defaults.copyWith(reduceMotion: reduce);\n  }\n\n")
    out.append(copy_with("DsMotion", [("Duration", k) for k in DURATION_ORDER] + [("Curve", k) for k in CURVE_ORDER]
                         + [("bool", "reduceMotion")]))
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
    consts = []
    for wc in WINDOW_ORDER[1:]:
        lo = bp[wc]["min"]
        hi = bp[wc]["maxExclusive"]
        rng = f"{lo}-{hi - 1}" if hi is not None else f">= {lo}"
        consts.append(f"  /// `ds.breakpoint.{wc}`: {rng} lp.\n  static const double {wc} = {num(lo)};\n")
    out.append(documented(consts))
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
    out.append("  /// Card grid columns (03 §7.3): max(2, min(6, floor((W + gap) / (minCardWidth + gap)))).\n")
    out.append("  /// [contentWidth] is the content zone WITHOUT side margins (on `large` - at most\n")
    out.append("  /// [contentMaxLarge], applied by the caller). [minCardWidth] defaults to [cardMinWidth];\n")
    out.append("  /// the catalog grid SCR-10/11/12 passes [catalogCardMinWidth] (ADR-111).\n")
    out.append("  static int gridColumns(double contentWidth, double gap, {double minCardWidth = cardMinWidth}) {\n")
    out.append("    final int n = ((contentWidth + gap) / (minCardWidth + gap)).floor();\n")
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
    # A switch expression always splits its cases: they sit 2 spaces deeper than the member, `};` at its level.
    for p, doc in props:
        vals = " / ".join(num(den[d][p]) for d in DENSITY_ORDER)
        out.append(f"  /// {doc}: {vals}.\n")
        out.append(f"  double get {p} => switch (this) {{\n")
        for d in DENSITY_ORDER:
            out.append(f"    DsDensity.{d} => {dbl(den[d][p])},\n")
        out.append("  };\n\n")
    out.append("  /// compact/medium -> standard; expanded/large -> compact.\n")
    out.append("  static DsDensity forWindowClass(WindowClass c) => switch (c) {\n")
    for wc in WINDOW_ORDER:
        d = next(d for d in DENSITY_ORDER if wc in den[d]["windowClasses"])
        out.append(f"    WindowClass.{wc} => DsDensity.{d},\n")
    out.append("  };\n}\n")
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
