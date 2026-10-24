// Golden-тесты дизайн-системы RM-C-003 (alchemist): разделы витрины `/dev/gallery` и каркас
// `AdaptiveScaffold` на трёх брейкпоинтах compact / medium / expanded (03 §7.2), палитра B;
// кнопки и поля дополнительно — при масштабе текста 1.3× (03 §17.1, A11Y-005).
//
// Обновить эталоны: flutter test --tags golden --update-goldens
// Проверить:        flutter test --tags golden
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/gallery/ds_showcase.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Брейкпоинты golden-тестов: ширина окна и высота каркаса.
const Map<WindowClass, Size> goldenWindows = <WindowClass, Size>{
  WindowClass.compact: Size(360, 760),
  WindowClass.medium: Size(800, 640),
  WindowClass.expanded: Size(1280, 800),
};

/// Окружение golden-сцены: `MediaQuery` окна заданного класса (компоненты читают класс окна
/// по ширине), reduce-motion (статичные кадры вместо бесконечных анимаций), локаль `ru`.
class GoldenWindow extends StatelessWidget {
  /// Создаёт окружение.
  const GoldenWindow({super.key, required this.size, required this.child, this.fixedHeight = false});

  /// Размер окна.
  final Size size;

  /// Содержимое.
  final Widget child;

  /// Фиксировать высоту (каркас); иначе — по содержимому.
  final bool fixedHeight;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData base = MediaQuery.of(context);
    return MediaQuery(
      data: base.copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
      child: Localizations(
        locale: const Locale('ru'),
        delegates: AppLocalizations.localizationsDelegates,
        child: Material(
          color: DsColors.lightB.background,
          child: SizedBox(
            width: size.width,
            height: fixedHeight ? size.height : null,
            child: fixedHeight ? child : Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    );
  }
}

void main() {
  for (final MapEntry<WindowClass, Size> w in goldenWindows.entries) {
    final String wc = w.key.name;
    group('дизайн-система · $wc (${w.value.width.toInt()} lp)', () {
      for (final DsShowcaseSection s in DsShowcase.sections) {
        unawaited(
          goldenTest(
            '${s.id} · $wc',
            fileName: 'ds_${s.id}_$wc',
            constraints: BoxConstraints.tightFor(width: w.value.width),
            builder: () => GoldenWindow(
              size: w.value,
              child: Builder(builder: s.builder),
            ),
          ),
        );
      }
      unawaited(
        goldenTest(
          'AdaptiveScaffold · $wc',
          fileName: 'ds_scaffold_$wc',
          constraints: BoxConstraints.tight(w.value),
          builder: () => GoldenWindow(
            size: w.value,
            fixedHeight: true,
            child: const Builder(builder: DsShowcase.scaffold),
          ),
        ),
      );
    });
  }

  group('масштаб текста 1.3× (A11Y-005)', () {
    for (final String id in <String>['buttons', 'inputs']) {
      final DsShowcaseSection s = DsShowcase.sections.firstWhere((DsShowcaseSection x) => x.id == id);
      unawaited(
        goldenTest(
          '$id · compact · 1.3×',
          fileName: 'ds_${id}_compact_text130',
          textScaleFactor: 1.3,
          constraints: BoxConstraints.tightFor(width: goldenWindows[WindowClass.compact]!.width),
          builder: () => GoldenWindow(
            size: goldenWindows[WindowClass.compact]!,
            child: Builder(builder: s.builder),
          ),
        ),
      );
    }
  });
}
