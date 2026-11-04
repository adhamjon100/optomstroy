// RM-C-003 критерий 1: значения Dart (lib/design_system/tokens, сгенерированы
// scripts/gen_tokens_dart.py) совпадают с contracts/design-tokens/tokens.json (RM-B-006) —
// 0 расхождений. Дополнительно: контраст пар `contrast.pairs` на DsColors.lightB (T-DS-001…012,
// эквивалент check_contrast.py) и сопоставление AppTheme → ColorScheme/TextTheme (03 §17.3, §17.7).
// T-DS-104 (ADR-114, tokens.json 1.2.0): компонентные цвета, стили Inter 800, радиусы, тени и геометрия
// каталога прототипа = tokens.json; пары CP-091…; исключения — только 4 пары ADR-114, AA-оттенки их закрывают.
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

import 'ds_test_support.dart';

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

/// Компонентные цвета DsColors (`componentColor`, ADR-114) по имени токена, тоже явным перечнем.
Map<String, Color> dsComponentColorMap(DsColors c) => <String, Color>{
  'catalogMeta': c.catalogMeta,
  'catalogMetaOnPage': c.catalogMetaOnPage,
  'catalogName': c.catalogName,
  'drawerFooterBg': c.drawerFooterBg,
  'favoriteOutline': c.favoriteOutline,
  'link': c.link,
  'neutralButtonBorder': c.neutralButtonBorder,
  'photoPlaceholderBg': c.photoPlaceholderBg,
  'photoPlaceholderIcon': c.photoPlaceholderIcon,
  'photoPlaceholderText': c.photoPlaceholderText,
  'ribbonGlyph': c.ribbonGlyph,
  'ribbonPlaceholderBg': c.ribbonPlaceholderBg,
  'rowDivider': c.rowDivider,
  'searchPlaceholder': c.searchPlaceholder,
  'segmentIdleText': c.segmentIdleText,
  'stockIn': c.stockIn,
  'stockLowIcon': c.stockLowIcon,
  'stockLowText': c.stockLowText,
  'stockOutIcon': c.stockOutIcon,
  'stockOutText': c.stockOutText,
  'toastBg': c.toastBg,
  'toastCheck': c.toastCheck,
};

/// Стили прототипа DsTypography (`text.component`, ADR-114) по имени.
Map<String, TextStyle> dsComponentTextMap(DsTypography d) => <String, TextStyle>{
  'avatarInitial': d.avatarInitial,
  'bellBadge': d.bellBadge,
  'brandWordmark': d.brandWordmark,
  'cardName': d.cardName,
  'cartBadge': d.cartBadge,
  'cartTotal': d.cartTotal,
  'catalogPrice': d.catalogPrice,
  'catalogTitle': d.catalogTitle,
  'chip': d.chip,
  'columnTitle': d.columnTitle,
  'compactPrice': d.compactPrice,
  'drawerTitle': d.drawerTitle,
  'lineSum': d.lineSum,
  'listName': d.listName,
  'listPrice': d.listPrice,
  'meta': d.meta,
  'ribbonLabel': d.ribbonLabel,
  'sku': d.sku,
  'sortLabel': d.sortLabel,
  'stock': d.stock,
  'tileLabel': d.tileLabel,
  'totalLabel': d.totalLabel,
};

/// Исключения ADR-114 (решение владельца 1, 2026-10-31) — тот же перечень, что ADR114_EXCEPTIONS в check_contrast.py.
const Set<String> adr114Exceptions = <String>{
  'catalogMetaOnPage/background/text',
  'searchPlaceholder/surfaceVariant/text',
  'photoPlaceholderText/photoPlaceholderBg/text',
  'favoriteOutline/surface/non-text',
};

/// Исключения самой WCAG (неактивные элементы, логотип) — WCAG_EXCEPTIONS в check_contrast.py.
const Set<String> wcagExceptions = <String>{
  'disabledText/disabledBg/text',
  'brandAccent/surface/non-text',
  'catalogMeta/disabledBg/text',
};

/// Различия значений [json] (имя → HEX или {value, use}) и цветов [dart] по одному набору имён.
List<String> colorDiffs(Map<String, Object?> json, Map<String, Color> dart) => <String>[
  for (final MapEntry<String, Object?> e in json.entries)
    if (dart[e.key]!.toARGB32() != _jsonColor(e.value is Map ? _obj(e.value)['value'] : e.value).toARGB32())
      '${e.key}: dart ${dart[e.key]} != json ${e.value}',
];

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

  test('T-DS-104: компонентные цвета DsColors.lightB = tokens.json componentColor (ADR-114, точно по прототипу)', () {
    final Map<String, Object?> json = _obj(t['componentColor']);
    final Map<String, Color> dart = dsComponentColorMap(DsColors.lightB);
    expect(dart.keys.toSet(), json.keys.toSet(), reason: 'набор компонентных цветов');
    expect(dart.keys.toSet().intersection(_obj(t['color']).keys.toSet()), isEmpty, reason: 'имена не пересекаются');
    expect(colorDiffs(json, dart), isEmpty);
    // Решение владельца 1 (2026-10-31): цвета прототипа точно, в том числе 4 пары ниже нормы.
    const DsColors c = DsColors.lightB;
    expect(c.catalogName, const Color(0xFF16206A));
    expect(c.catalogMeta, const Color(0xFF6B7487));
    expect(c.catalogMetaOnPage, const Color(0xFF6B7487));
    expect(c.searchPlaceholder, const Color(0xFF757575));
    expect(c.photoPlaceholderText, const Color(0xFF7D879A));
    expect(c.favoriteOutline, const Color(0xFFE2A93B));
    expect(c.favoriteOutline, c.favorite, reason: 'контур и заливка звезды — один цвет прототипа');
    expect(c.stockOutText, const Color(0xFF5F6878), reason: '«Нет в наличии» серым, не error');
    expect(c.link, const Color(0xFF1F5FA8));
    // Компонентные цвета не зависят от палитры: откат палитры их не меняет.
    expect(colorDiffs(json, dsComponentColorMap(DsColors.lightB20261021)), isEmpty);
  });

  test('T-DS-104: AA-оттенки ADR-114 — DsColors.lightAA20261031 = палитра B + alternatives.AA_2026_10_31', () {
    final Map<String, Object?> alt = _obj(_obj(t['alternatives'])['AA_2026_10_31']);
    expect(alt['status'], 'aa-variant');
    final Map<String, Object?> swaps = _obj(alt['componentColor']);
    expect(swaps.keys.toSet(), <String>{
      'catalogMetaOnPage',
      'favoriteOutline',
      'photoPlaceholderText',
      'searchPlaceholder',
    });
    const DsColors aa = DsColors.lightAA20261031;
    // Палитра — B без изменений.
    final Map<String, Color> b = dsColorMap(DsColors.lightB);
    expect(<String>[
      for (final MapEntry<String, Color> e in dsColorMap(aa).entries)
        if (e.value != b[e.key]) e.key,
    ], isEmpty);
    // Компонентные: заменены ровно 4, остальные = основные.
    final Map<String, Object?> expected = <String, Object?>{..._obj(t['componentColor']), ...swaps};
    expect(colorDiffs(expected, dsComponentColorMap(aa)), isEmpty);
    expect(aa.favoriteOutline, const Color(0xFFBC8D31));
    expect(aa.catalogMetaOnPage, const Color(0xFF687184));
    expect(aa.photoPlaceholderText, const Color(0xFF6A7282));
    expect(aa.searchPlaceholder, const Color(0xFF6D6D6D));
    // Норма контраста с AA-оттенками (A11Y-002): текст ≥ 4.5, контур звезды ≥ 3.
    expect(contrastRatio(aa.catalogMetaOnPage, aa.background), greaterThanOrEqualTo(4.5));
    expect(contrastRatio(aa.searchPlaceholder, aa.surfaceVariant), greaterThanOrEqualTo(4.5));
    expect(contrastRatio(aa.photoPlaceholderText, aa.photoPlaceholderBg), greaterThanOrEqualTo(4.5));
    expect(contrastRatio(aa.favoriteOutline, aa.surface), greaterThanOrEqualTo(3.0));
    expect(AppTheme.light(colors: aa).extension<DsColors>(), same(aa), reason: 'включается одной строкой');
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

  test('T-DS-104: стили прототипа DsTypography = tokens.json text.component (ADR-114, Inter 800)', () {
    final Map<String, Object?> comp = _obj(_obj(t['text'])['component']);
    const DsTypography d = DsTypography.inter;
    final Map<String, TextStyle> dart = dsComponentTextMap(d);
    expect(dart.keys.toSet(), comp.keys.toSet());
    for (final MapEntry<String, Object?> e in comp.entries) {
      final Map<String, Object?> s = _obj(e.value);
      final TextStyle ts = dart[e.key]!;
      expect(ts.fontFamily, 'Inter', reason: e.key);
      expect(ts.fontSize, _num(s['fontSize']), reason: '${e.key}.fontSize');
      if (s.containsKey('lineHeight')) {
        expect(
          ts.fontSize! * ts.height!,
          closeTo(_num(s['lineHeight']).toDouble(), 1e-9),
          reason: '${e.key}.lineHeight',
        );
      } else {
        expect(ts.height, _num(s['height']), reason: '${e.key}.height');
      }
      expect(ts.fontWeight!.value, _num(s['fontWeight']), reason: '${e.key}.fontWeight');
      expect(ts.letterSpacing, _num(s['letterSpacing']), reason: '${e.key}.letterSpacing');
      expect(ts.fontFeatures ?? const <FontFeature>[], s['tabularFigures'] == true ? DsTypography.numeric : isEmpty);
    }
    // Выбранное состояние: вес 700, остальное — как у основного стиля.
    expect(d.ribbonLabelSelected.fontWeight!.value, _num(_obj(comp['ribbonLabel'])['fontWeightSelected']));
    expect(d.tileLabelSelected.fontWeight!.value, _num(_obj(comp['tileLabel'])['fontWeightSelected']));
    expect(d.tileLabelSelected.fontSize, d.tileLabel.fontSize);
    // Значения прототипа без округления (план ADR-114, appChanges[0]).
    expect(
      <Object?>[d.catalogTitle.fontSize, d.catalogTitle.fontWeight, d.catalogTitle.letterSpacing],
      <Object?>[30, FontWeight.w800, -0.4],
    );
    expect(
      <Object?>[d.catalogPrice.fontSize, d.catalogPrice.fontWeight, d.catalogPrice.letterSpacing],
      <Object?>[18, FontWeight.w800, -0.2],
    );
    expect(<Object?>[d.brandWordmark.fontSize, d.brandWordmark.fontWeight], <Object?>[21, FontWeight.w700]);
    expect(
      <double?>[d.cartTotal.fontSize, d.listPrice.fontSize, d.lineSum.fontSize, d.compactPrice.fontSize],
      <double>[24, 17, 15, 14],
    );
    expect(d.stock.fontSize, 12.5);
    expect(d.cardName.height, 1.32);
    expect(d.columnTitle.fontSize! * d.columnTitle.height!, closeTo(23, 0.02), reason: 'блок «Каталог» 23 (19 × 1.21)');
  });

  test('T-DS-104: начертание Inter 800 в сборке (pubspec, файл, отрисовка шире 700)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const String asset = 'assets/fonts/Inter/Inter-ExtraBold.ttf';
    expect(File(asset).existsSync(), isTrue, reason: asset);
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- asset: $asset\n          weight: 800'), reason: 'pubspec: семейство Inter, weight 800');
    expect(interStaticFiles, contains(asset), reason: 'ds_test_support загружает 800');
    await loadInterFont();
    double widthOf(FontWeight w) {
      final TextPainter p = TextPainter(
        text: TextSpan(
          text: 'Ж 10 450,00 сом',
          style: TextStyle(fontFamily: DsTypography.fontFamily, fontSize: 30, fontWeight: w),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final double width = p.width;
      p.dispose();
      return width;
    }

    // Без файла 800 Flutter подставил бы 700, и ширины совпали бы.
    expect(widthOf(FontWeight.w800), greaterThan(widthOf(FontWeight.w700)));
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
      // Радиусы прототипа (ADR-114).
      'segment': r.segment,
      'badge': r.badge,
      'control': r.control,
      'catalogCard': r.catalogCard,
      'star': r.star,
      'arrow': r.arrow,
      'avatar': r.avatar,
      'circle': r.circle,
    };
    expect(rd.keys.toSet(), radius.keys.toSet());
    for (final MapEntry<String, Radius> e in rd.entries) {
      expect(e.value, Radius.circular(_num(radius[e.key]).toDouble()), reason: 'radius.${e.key}');
    }
    // T-DS-104: seg 7, sm 8, badge 9, control 10, md 12, card 14, star 17, arrow/avatar 19, circle 28.
    expect(
      <double>[r.segment.x, r.sm.x, r.badge.x, r.control.x, r.md.x, r.catalogCard.x, r.star.x, r.arrow.x, r.avatar.x],
      <double>[7, 8, 9, 10, 12, 14, 17, 19, 19],
    );
    expect(r.circle.x, 28);
    expect(r.card, BorderRadius.all(r.md), reason: 'геттер 03 §17.4 не меняется');
    final Map<String, Object?> bp = _obj(t['breakpoint']);
    expect(s.pagePaddingCompact.left, _num(_obj(bp['compact'])['pageMargin']));
    expect(s.pagePaddingMedium.left, _num(_obj(bp['medium'])['pageMargin']));
    expect(s.pagePaddingLarge.left, _num(_obj(bp['large'])['pageMargin']));
  });

  test('ds.elevation.*: тени и overlay', () {
    final Map<String, Object?> el = _obj(t['elevation']);
    const DsElevation e = DsElevation.defaults;
    final Map<String, List<BoxShadow>> dart = <String, List<BoxShadow>>{
      '0': e.e0,
      '1': e.e1,
      '2': e.e2,
      '3': e.e3,
      // Тени прототипа (ADR-114) на основе textPrimary rgba(14,20,86,a).
      'cardHover': e.cardHover,
      'ribbonArrow': e.ribbonArrow,
      'drawer': e.drawer,
      'toast': e.toast,
    };
    expect(dart.keys.toSet(), el.keys.toSet());
    for (final String k in <String>['cardHover', 'ribbonArrow', 'drawer', 'toast']) {
      final Map<String, Object?> level = _obj(el[k]);
      expect(level['baseColor'], 'textPrimary', reason: 'elevation.$k.baseColor');
      for (final BoxShadow b in dart[k]!) {
        expect(b.color.withValues(alpha: 1).toARGB32(), DsColors.lightB.textPrimary.toARGB32(), reason: 'elevation.$k');
      }
    }
    expect(e.cardHover.single.offset, const Offset(0, 6));
    expect(e.cardHover.single.blurRadius, 18);
    expect(e.drawer.single.offset, const Offset(-12, 0));
    expect(e.toast.single.color.a, closeTo(0.30, 1e-9));
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
    // T-DS-104 (ADR-114): auto-fill 176 с зазором 14 без предела колонок — 9/6/5/4 при W 1744/1264/1104/848
    // (vw 1920/1440/1280/1024 минус колонка 144 и поля 8 + 24); остальные экраны — по-прежнему не больше 6.
    int uncapped(double w) => DsBreakpoints.gridColumns(
      w,
      DsCatalogMetrics.gridGap,
      minCardWidth: DsCatalogMetrics.gridMinCard,
      maxColumns: null,
    );
    expect(<int>[uncapped(1744), uncapped(1264), uncapped(1104), uncapped(848)], <int>[9, 6, 5, 4]);
    expect(DsBreakpoints.gridColumns(1744, 14, minCardWidth: DsBreakpoints.catalogCardMinWidth), 6);
    expect(uncapped(100), DsBreakpoints.gridMinColumns, reason: 'нижний предел остаётся');
    // DsCatalogMetrics = tokens.json catalog.
    final Map<String, Object?> cat = _obj(t['catalog']);
    EdgeInsets insets(String k) {
      final Map<String, Object?> v = _obj(cat[k]);
      return EdgeInsets.fromLTRB(
        _num(v['left']).toDouble(),
        _num(v['top']).toDouble(),
        _num(v['right']).toDouble(),
        _num(v['bottom']).toDouble(),
      );
    }

    Size size2d(String k) => Size(_num(_obj(cat[k])['width']).toDouble(), _num(_obj(cat[k])['height']).toDouble());
    final Map<String, Object> metrics = <String, Object>{
      'columnMinWidth': DsCatalogMetrics.columnMinWidth,
      'columnPadding': DsCatalogMetrics.columnPadding,
      'tileGap': DsCatalogMetrics.tileGap,
      'tileMinHeight': DsCatalogMetrics.tileMinHeight,
      'tilePadding': DsCatalogMetrics.tilePadding,
      'tileArt': DsCatalogMetrics.tileArt,
      'ribbonCard': DsCatalogMetrics.ribbonCard,
      'ribbonGap': DsCatalogMetrics.ribbonGap,
      'ribbonPad': DsCatalogMetrics.ribbonPad,
      'ribbonArrowStepCards': DsCatalogMetrics.ribbonArrowStepCards,
      'mainPadding': DsCatalogMetrics.mainPadding,
      'gridMinCard': DsCatalogMetrics.gridMinCard,
      'gridGap': DsCatalogMetrics.gridGap,
      'gridCardHeight': DsCatalogMetrics.gridCardHeight,
      'gridCardHeightWrapped': DsCatalogMetrics.gridCardHeightWrapped,
      'toolbarHeight': DsCatalogMetrics.toolbarHeight,
      'chipHeight': DsCatalogMetrics.chipHeight,
      'segmentHeight': DsCatalogMetrics.segmentHeight,
    };
    expect(metrics.keys.toSet(), cat.keys.toSet());
    for (final MapEntry<String, Object> m in metrics.entries) {
      final Object expected = switch (m.value) {
        EdgeInsets() => insets(m.key),
        Size() => size2d(m.key),
        _ => _num(cat[m.key]),
      };
      expect(m.value, expected, reason: 'catalog.${m.key}');
    }
    expect(DsCatalogMetrics.columnPadding, const EdgeInsets.fromLTRB(18, 20, 14, 24));
    expect(DsCatalogMetrics.mainPadding, const EdgeInsets.fromLTRB(8, 18, 24, 40));
    expect(DsCatalogMetrics.columnMinWidth, DsBreakpoints.catalogColumn);
    expect(DsCatalogMetrics.gridMinCard, DsBreakpoints.catalogCardMinWidth);
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
    final Map<String, Color> colors = <String, Color>{
      ...dsColorMap(DsColors.lightB),
      ...dsComponentColorMap(DsColors.lightB),
    };
    Color resolve(String name) => name.startsWith('#') ? _jsonColor(name) : colors[name]!;
    final List<String> violations = <String>[];
    final List<String> mismatches = <String>[];
    // T-DS-104: статус exception — только у явного перечня (WCAG и 4 пары ADR-114), как в check_contrast.py.
    final List<String> unexpectedExceptions = <String>[];
    final Set<String> adr114Found = <String>{};
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
      final String key = '$fg/$bg/${pair['use']}';
      if (adr114Exceptions.contains(key)) {
        final double min = _num(thresholds[pair['use']]).toDouble();
        expect(pair['status'], 'exception', reason: '${pair['id']}: исключение ADR-114');
        expect(pair['decision'], 'ADR-114', reason: '${pair['id']}: решение записано');
        expect(ratio, lessThan(min), reason: '${pair['id']}: исключение действительно ниже нормы');
        adr114Found.add(key);
      } else {
        expect(pair['decision'], isNull, reason: '${pair['id']}: decision только у исключений ADR-114');
        if (pair['status'] == 'exception' && !wcagExceptions.contains(key)) {
          unexpectedExceptions.add('${pair['id']} $key');
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
    expect(unexpectedExceptions, isEmpty, reason: 'исключение вне явного перечня');
    expect(adr114Found, adr114Exceptions, reason: 'все 4 исключения ADR-114 на месте');
    // С AA-оттенками (DsColors.lightAA20261031) проходят и все allowed, и 4 исключения ADR-114.
    final Map<String, Color> aa = <String, Color>{
      ...dsColorMap(DsColors.lightAA20261031),
      ...dsComponentColorMap(DsColors.lightAA20261031),
    };
    Color resolveAa(String name) => name.startsWith('#') ? _jsonColor(name) : aa[name]!;
    final List<String> aaFails = <String>[];
    for (final Object? p in pairs) {
      final Map<String, Object?> pair = _obj(p);
      final String fg = pair['fg']! as String;
      final String bg = pair['bg']! as String;
      if (pair['status'] != 'allowed' && !adr114Exceptions.contains('$fg/$bg/${pair['use']}')) {
        continue;
      }
      final double ratio = contrastRatio(resolveAa(fg), resolveAa(bg));
      if (ratio + 1e-9 < _num(thresholds[pair['use']])) {
        aaFails.add('${pair['id']} $fg/$bg ${ratio.toStringAsFixed(2)}');
      }
    }
    expect(aaFails, isEmpty, reason: 'AA-оттенки ADR-114 закрывают все пары');
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
