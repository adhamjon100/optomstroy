// RM-C-003 критерий 1: значения Dart (lib/design_system/tokens, сгенерированы
// scripts/gen_tokens_dart.py) совпадают с contracts/design-tokens/tokens.json (RM-B-006) —
// 0 расхождений. Дополнительно: контраст пар `contrast.pairs` на DsColors.lightB (T-DS-001…012,
// эквивалент check_contrast.py) и сопоставление AppTheme → ColorScheme/TextTheme (03 §17.3, §17.7).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_density.dart';
import 'package:optomstroy/design_system/tokens/ds_elevation.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';
import 'package:optomstroy/design_system/tokens/ds_radii.dart';
import 'package:optomstroy/design_system/tokens/ds_spacing.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Путь к источнику истины относительно корня пакета pos-app (cwd `flutter test`).
/// `--dart-define=DS_TOKENS_JSON=<путь>` — отрицательная проверка теста на изменённой копии.
const String tokensPath = String.fromEnvironment(
  'DS_TOKENS_JSON',
  defaultValue: '../contracts/design-tokens/tokens.json',
);

Map<String, Object?> _obj(Object? v) => (v! as Map<Object?, Object?>).cast<String, Object?>();
num _num(Object? v) => v! as num;

Color _jsonColor(Object? v) {
  if (v is String) {
    return Color(int.parse('FF${v.substring(1)}', radix: 16));
  }
  final Map<String, Object?> m = _obj(v);
  final String rgb = m['rgb']! as String;
  return Color.fromRGBO(
    int.parse(rgb.substring(1, 3), radix: 16),
    int.parse(rgb.substring(3, 5), radix: 16),
    int.parse(rgb.substring(5, 7), radix: 16),
    _num(m['opacity']).toDouble(),
  );
}

/// Все поля DsColors по имени токена (поля перечислены явно: пропуск поля = расхождение).
Map<String, Color> dsColorMap(DsColors c) => <String, Color>{
  'background': c.background,
  'border': c.border,
  'borderStrong': c.borderStrong,
  'brandAccent': c.brandAccent,
  'disabledBg': c.disabledBg,
  'disabledText': c.disabledText,
  'error': c.error,
  'errorContainer': c.errorContainer,
  'favorite': c.favorite,
  'focus': c.focus,
  'iconButtonPressed': c.iconButtonPressed,
  'info': c.info,
  'infoContainer': c.infoContainer,
  'inverseSurface': c.inverseSurface,
  'onBrandAccent': c.onBrandAccent,
  'onError': c.onError,
  'onInverseSurface': c.onInverseSurface,
  'onPrimary': c.onPrimary,
  'onPrimaryContainer': c.onPrimaryContainer,
  'onSuccess': c.onSuccess,
  'overlay': c.overlay,
  'primary': c.primary,
  'primaryContainer': c.primaryContainer,
  'primaryContainerBorder': c.primaryContainerBorder,
  'primaryContainerPressed': c.primaryContainerPressed,
  'primaryHover': c.primaryHover,
  'primaryPressed': c.primaryPressed,
  'primaryText': c.primaryText,
  'skeletonBase': c.skeletonBase,
  'skeletonHighlight': c.skeletonHighlight,
  'success': c.success,
  'successContainer': c.successContainer,
  'surface': c.surface,
  'surfaceHover': c.surfaceHover,
  'surfacePressed': c.surfacePressed,
  'surfaceVariant': c.surfaceVariant,
  'textPrimary': c.textPrimary,
  'textSecondary': c.textSecondary,
  'textTertiary': c.textTertiary,
  'warning': c.warning,
  'warningContainer': c.warningContainer,
};

/// Относительная яркость WCAG 2.x.
double _luminance(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// Коэффициент контраста WCAG.
double contrastRatio(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  late Map<String, Object?> t;

  setUpAll(() {
    t = _obj(jsonDecode(File(tokensPath).readAsStringSync()));
  });

  test('палитра — B, тема — light (ядро v1.9 §24.1, D-43)', () {
    final Map<String, Object?> meta = _obj(t['meta']);
    expect(meta['palette'], 'B');
    expect(meta['theme'], 'light');
    expect(identical(DsColors.light, DsColors.lightB), isTrue);
  });

  test('ds.color.*: набор и значения DsColors.lightB = tokens.json', () {
    final Map<String, Object?> json = _obj(t['color']);
    final Map<String, Color> dart = dsColorMap(DsColors.lightB);
    expect(dart.keys.toSet(), json.keys.toSet(), reason: 'набор токенов цвета');
    final List<String> diffs = <String>[
      for (final MapEntry<String, Object?> e in json.entries)
        if (dart[e.key]!.toARGB32() != _jsonColor(e.value).toARGB32())
          '${e.key}: dart ${dart[e.key]} != json ${e.value}',
    ];
    expect(diffs, isEmpty);
  });

  test('откат ADR-111: DsColors.lightB20261021 = alternatives.B_2026_10_21 (status rollback)', () {
    final Map<String, Object?> alt = _obj(_obj(t['alternatives'])['B_2026_10_21']);
    expect(alt['status'], 'rollback');
    final Map<String, Object?> json = _obj(alt['color']);
    final Map<String, Color> dart = dsColorMap(DsColors.lightB20261021);
    expect(dart.keys.toSet(), json.keys.toSet(), reason: 'набор токенов цвета отката');
    final List<String> diffs = <String>[
      for (final MapEntry<String, Object?> e in json.entries)
        if (dart[e.key]!.toARGB32() != _jsonColor(e.value).toARGB32())
          '${e.key}: dart ${dart[e.key]} != json ${e.value}',
    ];
    expect(diffs, isEmpty);
    // Прежняя палитра: оранжевый #FF8700 с тёмным onPrimary; новые ключи = border и primaryText набора.
    expect(DsColors.lightB20261021.primary, const Color(0xFFFF8700));
    expect(DsColors.lightB20261021.primaryContainerBorder, DsColors.lightB20261021.border);
    expect(DsColors.lightB20261021.onPrimaryContainer, DsColors.lightB20261021.primaryText);
    expect(AppTheme.light(colors: DsColors.lightB20261021).extension<DsColors>(), same(DsColors.lightB20261021));
  });

  test('палитра B по ADR-111: primary #D9380F, белый onPrimary, тинт и его рамка', () {
    const DsColors c = DsColors.lightB;
    expect(c.primary, const Color(0xFFD9380F));
    expect(c.onPrimary, const Color(0xFFFFFFFF));
    expect(c.primaryContainerBorder, const Color(0xFFF5C6B6));
    expect(c.onPrimaryContainer, const Color(0xFFA82A09));
    expect(c.brandAccent, const Color(0xFFFF8700), reason: 'логотип не меняется');
    expect(contrastRatio(c.onPrimaryContainer, c.primaryContainer), greaterThanOrEqualTo(4.5));
    expect(contrastRatio(c.onPrimaryContainer, c.primaryContainerPressed), greaterThanOrEqualTo(4.5));
  });

  test('ds.text.*: шкала DsTypography.inter = tokens.json', () {
    final Map<String, Object?> text = _obj(t['text']);
    expect(DsTypography.fontFamily, text['fontFamily']);
    expect(DsTypography.numeric, contains(const FontFeature.tabularFigures()));
    final Map<String, Object?> styles = _obj(text['styles']);
    const DsTypography d = DsTypography.inter;
    final Map<String, TextStyle> dart = <String, TextStyle>{
      'display': d.display,
      'h1': d.h1,
      'h2': d.h2,
      'h3': d.h3,
      'title': d.title,
      'bodyLg': d.bodyLg,
      'body': d.body,
      'label': d.label,
      'caption': d.caption,
      'micro': d.micro,
    };
    expect(dart.keys.toSet(), styles.keys.toSet());
    for (final MapEntry<String, Object?> e in styles.entries) {
      final Map<String, Object?> s = _obj(e.value);
      final TextStyle ts = dart[e.key]!;
      expect(ts.fontFamily, 'Inter', reason: e.key);
      expect(ts.fontSize, _num(s['fontSize']), reason: '${e.key}.fontSize');
      expect(ts.fontSize! * ts.height!, closeTo(_num(s['lineHeight']).toDouble(), 1e-9), reason: '${e.key}.lineHeight');
      expect(ts.fontWeight!.value, _num(s['fontWeight']), reason: '${e.key}.fontWeight');
      expect(ts.letterSpacing, _num(s['letterSpacing']), reason: '${e.key}.letterSpacing');
    }
    expect(d.bodyLgMedium.fontWeight!.value, _num(_obj(styles['bodyLg'])['fontWeightMedium']));
    expect(d.bodyMedium.fontWeight!.value, _num(_obj(styles['body'])['fontWeightMedium']));
    expect(d.captionMedium.fontWeight!.value, _num(_obj(styles['caption'])['fontWeightMedium']));
    final Map<String, Object?> price = _obj(text['price']);
    expect(d.price.fontWeight!.value, _num(price['fontWeight']));
    expect(d.price.fontSize, dart[price['base']! as String]!.fontSize);
    expect(d.price.fontFeatures, contains(const FontFeature.tabularFigures()));
  });

  test('ds.space.*, ds.radius.*', () {
    final Map<String, Object?> space = _obj(t['space']);
    const DsSpacing s = DsSpacing.defaults;
    final List<double> dart = <double>[s.s1, s.s2, s.s3, s.s4, s.s5, s.s6, s.s7, s.s8, s.s9, s.s10];
    expect(space.length, dart.length);
    for (int i = 0; i < dart.length; i++) {
      expect(dart[i], _num(space['${i + 1}']), reason: 'space.${i + 1}');
    }
    final Map<String, Object?> radius = _obj(t['radius']);
    const DsRadii r = DsRadii.defaults;
    final Map<String, Radius> rd = <String, Radius>{
      'xs': r.xs,
      'sm': r.sm,
      'md': r.md,
      'lg': r.lg,
      'xl': r.xl,
      'full': r.full,
    };
    expect(rd.keys.toSet(), radius.keys.toSet());
    for (final MapEntry<String, Radius> e in rd.entries) {
      expect(e.value, Radius.circular(_num(radius[e.key]).toDouble()), reason: 'radius.${e.key}');
    }
    final Map<String, Object?> bp = _obj(t['breakpoint']);
    expect(s.pagePaddingCompact.left, _num(_obj(bp['compact'])['pageMargin']));
    expect(s.pagePaddingMedium.left, _num(_obj(bp['medium'])['pageMargin']));
    expect(s.pagePaddingLarge.left, _num(_obj(bp['large'])['pageMargin']));
  });

  test('ds.elevation.*: тени и overlay', () {
    final Map<String, Object?> el = _obj(t['elevation']);
    const DsElevation e = DsElevation.defaults;
    final Map<String, List<BoxShadow>> dart = <String, List<BoxShadow>>{'0': e.e0, '1': e.e1, '2': e.e2, '3': e.e3};
    expect(dart.keys.toSet(), el.keys.toSet());
    for (final MapEntry<String, List<BoxShadow>> d in dart.entries) {
      final List<Object?> shadows = _obj(el[d.key])['shadows']! as List<Object?>;
      expect(d.value.length, shadows.length, reason: 'elevation.${d.key}');
      for (int i = 0; i < shadows.length; i++) {
        final Map<String, Object?> js = _obj(shadows[i]);
        final BoxShadow b = d.value[i];
        expect(b.offset, Offset(_num(js['x']).toDouble(), _num(js['y']).toDouble()));
        expect(b.blurRadius, _num(js['blur']));
        expect(b.spreadRadius, _num(js['spread']));
        expect(b.color.toARGB32(), _jsonColor(js['color']).toARGB32());
      }
    }
    expect(e.overlay.toARGB32(), _jsonColor(_obj(t['color'])['overlay']).toARGB32());
  });

  test('ds.breakpoint.*, layout, density', () {
    final Map<String, Object?> bp = _obj(t['breakpoint']);
    expect(DsBreakpoints.medium, _num(_obj(bp['medium'])['min']));
    expect(DsBreakpoints.expanded, _num(_obj(bp['expanded'])['min']));
    expect(DsBreakpoints.large, _num(_obj(bp['large'])['min']));
    expect(WindowClass.values.map((WindowClass w) => w.name).toSet(), bp.keys.toSet());
    final Map<String, Object?> lay = _obj(t['layout']);
    final Map<String, num> dart = <String, num>{
      'sidebarNarrow': DsBreakpoints.sidebarNarrow,
      'sidebarWide': DsBreakpoints.sidebarWide,
      'sidebarCollapsed': DsBreakpoints.sidebarCollapsed,
      'rail': DsBreakpoints.rail,
      'cartNarrow': DsBreakpoints.cartNarrow,
      'cartWide': DsBreakpoints.cartWide,
      'productPanel': DsBreakpoints.productPanel,
      'contentMaxLarge': DsBreakpoints.contentMaxLarge,
      'cardMinWidth': DsBreakpoints.cardMinWidth,
      'topBarHeight': DsBreakpoints.topBarHeight,
      'navDrawer': DsBreakpoints.navDrawer,
      'cartDrawer': DsBreakpoints.cartDrawer,
      'catalogColumn': DsBreakpoints.catalogColumn,
      'catalogCardMinWidth': DsBreakpoints.catalogCardMinWidth,
      'gridMinColumns': DsBreakpoints.gridMinColumns,
      'gridMaxColumns': DsBreakpoints.gridMaxColumns,
    };
    expect(dart.keys.toSet(), lay.keys.toSet());
    for (final MapEntry<String, num> e in dart.entries) {
      expect(e.value, _num(lay[e.key]), reason: 'layout.${e.key}');
    }
    // Layout-токены прототипа (ADR-111): шапка, drawer навигации и корзины, колонка и карточка каталога.
    expect(
      <double>[
        DsBreakpoints.topBarHeight,
        DsBreakpoints.navDrawer,
        DsBreakpoints.cartDrawer,
        DsBreakpoints.catalogColumn,
        DsBreakpoints.catalogCardMinWidth,
      ],
      <double>[68, 320, 420, 132, 176],
    );
    // gridColumns: по умолчанию cardMinWidth (160), каталог передаёт catalogCardMinWidth (176).
    expect(DsBreakpoints.gridColumns(700, 16), 4);
    expect(DsBreakpoints.gridColumns(700, 16, minCardWidth: DsBreakpoints.catalogCardMinWidth), 3);
    expect(DsBreakpoints.gridColumns(1200, 16, minCardWidth: DsBreakpoints.catalogCardMinWidth), 6);
    expect(DsBreakpoints.gridColumns(100, 16, minCardWidth: DsBreakpoints.catalogCardMinWidth), 2);
    final Map<String, Object?> den = _obj(t['density']);
    expect(DsDensity.values.map((DsDensity d) => d.name).toSet(), den.keys.toSet());
    for (final DsDensity d in DsDensity.values) {
      final Map<String, Object?> j = _obj(den[d.name]);
      expect(d.rowHeight, _num(j['rowHeight']));
      expect(d.rowHeightWithThumb, _num(j['rowHeightWithThumb']));
      expect(d.cardPadding, _num(j['cardPadding']));
      expect(d.rowIconSize, _num(j['rowIconSize']));
      expect(d.gridGap, _num(j['gridGap']));
      for (final Object? wc in j['windowClasses']! as List<Object?>) {
        final WindowClass w = WindowClass.values.byName(wc! as String);
        expect(DsDensityValues.forWindowClass(w), d, reason: '$wc → ${d.name}');
      }
    }
  });

  test('ds.motion.*: длительности и кривые', () {
    final Map<String, Object?> m = _obj(t['motion']);
    final Map<String, Object?> dur = _obj(m['duration']);
    const DsMotion mo = DsMotion.defaults;
    final Map<String, Duration> dd = <String, Duration>{
      'fast': mo.fast,
      'base': mo.base,
      'slow': mo.slow,
      'splashLogo': mo.splashLogo,
      'mascotTransition': mo.mascotTransition,
      'reducedCrossfade': mo.reducedCrossfade,
    };
    expect(dd.keys.toSet(), dur.keys.toSet());
    for (final MapEntry<String, Duration> e in dd.entries) {
      expect(e.value.inMilliseconds, _num(dur[e.key]), reason: 'motion.${e.key}');
    }
    final Map<String, Object?> curves = _obj(m['curve']);
    final Map<String, Curve> dc = <String, Curve>{
      'standard': mo.standard,
      'standardDecelerate': mo.standardDecelerate,
      'standardAccelerate': mo.standardAccelerate,
      'emphasized': mo.emphasized,
    };
    expect(dc.keys.toSet(), curves.keys.toSet());
    for (final MapEntry<String, Curve> e in dc.entries) {
      final Cubic c = e.value as Cubic;
      final List<num> p = (curves[e.key]! as List<Object?>).cast<num>();
      expect(<double>[c.a, c.b, c.c, c.d], <double>[for (final num x in p) x.toDouble()], reason: e.key);
    }
    expect(mo.reduceMotion, isFalse);
    expect(mo.copyWith(reduceMotion: true).of(mo.slow), Duration.zero);
  });

  test('контраст contrast.pairs на DsColors.lightB (T-DS-001…012, DS-098)', () {
    final Map<String, Object?> contrast = _obj(t['contrast']);
    final Map<String, Object?> thresholds = _obj(contrast['thresholds']);
    final Map<String, Color> colors = dsColorMap(DsColors.lightB);
    Color resolve(String name) => name.startsWith('#') ? _jsonColor(name) : colors[name]!;
    final List<String> violations = <String>[];
    final List<String> mismatches = <String>[];
    // ADR-111: «белый на primary» — allowed тогда и только тогда, когда ≥ 4.5 (как в check_contrast.py).
    final List<String> whiteOnPrimary = <String>[];
    final List<Object?> pairs = contrast['pairs']! as List<Object?>;
    expect(pairs, isNotEmpty);
    for (final Object? p in pairs) {
      final Map<String, Object?> pair = _obj(p);
      final String fg = pair['fg']! as String;
      final String bg = pair['bg']! as String;
      final double ratio = contrastRatio(resolve(fg), resolve(bg));
      final Object? documented = pair['documented'];
      if (documented != null && (ratio - _num(documented)).abs() > 0.01) {
        mismatches.add('${pair['id']}: ${ratio.toStringAsFixed(2)} != $documented');
      }
      if (pair['status'] == 'allowed') {
        final double min = _num(thresholds[pair['use']]).toDouble();
        if (ratio + 1e-9 < min) {
          violations.add('${pair['id']} $fg/$bg ${ratio.toStringAsFixed(2)} < $min');
        }
      }
      if (fg.toUpperCase() == '#FFFFFF' && bg == 'primary' && pair['use'] == 'text') {
        final bool consistent = (pair['status'] == 'allowed') == (ratio + 1e-9 >= 4.5);
        whiteOnPrimary.add(
          '${pair['id']} ${pair['status']} ${ratio.toStringAsFixed(2)}${consistent ? '' : ' — НЕСОГЛАСОВАНО'}',
        );
      }
    }
    expect(violations, isEmpty, reason: 'пары ниже порога');
    expect(mismatches, isEmpty, reason: 'расчёт расходится с опубликованным в 03');
    expect(whiteOnPrimary, hasLength(1), reason: 'пара «#FFFFFF на primary» (text) обязательна');
    expect(whiteOnPrimary.single, isNot(contains('НЕСОГЛАСОВАНО')), reason: 'allowed ⇔ ratio ≥ 4.5 (ADR-111)');
    expect(whiteOnPrimary.single, startsWith('CP-032 allowed'), reason: 'белый на #D9380F — 4.64:1, allowed');
  });

  test('AppTheme.light(): палитра B, Material 3, ColorScheme и TextTheme по 03 §17.3, §17.7', () {
    final ThemeData theme = AppTheme.light();
    const DsColors c = DsColors.lightB;
    expect(theme.useMaterial3, isTrue);
    expect(theme.brightness, Brightness.light);
    expect(theme.extension<DsColors>(), same(c));
    expect(theme.extension<DsTypography>(), isNotNull);
    expect(theme.extension<DsSpacing>(), isNotNull);
    expect(theme.extension<DsRadii>(), isNotNull);
    expect(theme.extension<DsElevation>(), isNotNull);
    expect(theme.extension<DsMotion>(), isNotNull);
    final ColorScheme s = theme.colorScheme;
    expect(s.primary, c.primary);
    expect(s.onPrimary, c.onPrimary);
    expect(s.surface, c.surface);
    expect(s.error, c.error);
    expect(s.onError, c.onError);
    expect(s.outline, c.borderStrong);
    expect(s.outlineVariant, c.border);
    expect(s.onPrimaryContainer, c.onPrimaryContainer);
    expect(s.surfaceContainerHighest, c.surfaceVariant);
    expect(s.inverseSurface, c.inverseSurface);
    expect(s.onInverseSurface, c.onInverseSurface);
    // DS-098: текстовые акценты Material — primaryText, не primary.
    expect(s.secondary, c.primaryText);
    expect(theme.textSelectionTheme.cursorColor, c.primaryText);
    expect(contrastRatio(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
    final TextTheme tt = theme.textTheme;
    const DsTypography d = DsTypography.inter;
    expect(tt.displaySmall!.fontSize, d.display.fontSize);
    expect(tt.headlineMedium!.fontSize, d.h1.fontSize);
    expect(tt.headlineSmall!.fontSize, d.h2.fontSize);
    expect(tt.titleLarge!.fontSize, d.h3.fontSize);
    expect(tt.titleMedium!.fontSize, d.title.fontSize);
    expect(tt.bodyLarge!.fontSize, d.bodyLg.fontSize);
    expect(tt.bodyMedium!.fontSize, d.body.fontSize);
    expect(tt.labelLarge!.fontSize, d.label.fontSize);
    expect(tt.bodySmall!.fontSize, d.caption.fontSize);
    expect(tt.labelSmall!.fontSize, d.micro.fontSize);
    expect(tt.bodyLarge!.fontFamily, 'Inter');
    expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
    expect(theme.splashFactory, NoSplash.splashFactory);
  });
}
