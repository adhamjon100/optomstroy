import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_density.dart';
import 'package:optomstroy/design_system/tokens/ds_elevation.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';
import 'package:optomstroy/design_system/tokens/ds_radii.dart';
import 'package:optomstroy/design_system/tokens/ds_spacing.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Доступ к токенам дизайн-системы из [BuildContext] (03 §17.7, DS-076).
///
/// Если тема не содержит расширения (например, виджет показан вне `AppTheme`),
/// возвращаются значения по умолчанию палитры B — компонент не падает.
abstract final class DsTheme {
  /// Цвета `ds.color.*`.
  static DsColors colorsOf(BuildContext c) => Theme.of(c).extension<DsColors>() ?? DsColors.light;

  /// Шкала текста `ds.text.*`.
  static DsTypography textOf(BuildContext c) => Theme.of(c).extension<DsTypography>() ?? DsTypography.inter;

  /// Отступы `ds.space.*`.
  static DsSpacing spaceOf(BuildContext c) => Theme.of(c).extension<DsSpacing>() ?? DsSpacing.defaults;

  /// Радиусы `ds.radius.*`.
  static DsRadii radiiOf(BuildContext c) => Theme.of(c).extension<DsRadii>() ?? DsRadii.defaults;

  /// Тени `ds.elevation.*`.
  static DsElevation elevationOf(BuildContext c) => Theme.of(c).extension<DsElevation>() ?? DsElevation.defaults;

  /// Длительности и кривые `ds.motion.*` с учётом reduce-motion.
  ///
  /// Два источника из трёх (03 §11.1) учитываются здесь: `MediaQuery.disableAnimations`
  /// и флаг ОС; третий — настройка SCR-42 — приходит через расширение темы
  /// (`DsMotion.reduceMotion = true`, его выставляет приложение).
  static DsMotion motionOf(BuildContext c) {
    final DsMotion base = Theme.of(c).extension<DsMotion>() ?? DsMotion.defaults;
    final bool reduce =
        base.reduceMotion ||
        (MediaQuery.maybeDisableAnimationsOf(c) ?? false) ||
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion;
    return reduce == base.reduceMotion ? base : base.copyWith(reduceMotion: reduce);
  }

  /// Класс окна по ширине `MediaQuery` (03 §7.2).
  static WindowClass windowClassOf(BuildContext c) => DsBreakpoints.of(c);

  /// Плотность для класса окна (03 §8.1).
  static DsDensity densityOf(BuildContext c) => DsDensityValues.forWindowClass(windowClassOf(c));
}

/// Короткий доступ к токенам: `context.colors`, `context.text`, … (03 §17.7).
extension DsContext on BuildContext {
  /// Цвета `ds.color.*`.
  DsColors get colors => DsTheme.colorsOf(this);

  /// Шкала текста `ds.text.*`.
  DsTypography get text => DsTheme.textOf(this);

  /// Отступы `ds.space.*`.
  DsSpacing get space => DsTheme.spaceOf(this);

  /// Радиусы `ds.radius.*`.
  DsRadii get radii => DsTheme.radiiOf(this);

  /// Тени `ds.elevation.*`.
  DsElevation get elevation => DsTheme.elevationOf(this);

  /// Анимации `ds.motion.*` (с учётом reduce-motion).
  DsMotion get motion => DsTheme.motionOf(this);

  /// Класс окна (03 §7.2).
  WindowClass get windowClass => DsTheme.windowClassOf(this);

  /// Плотность (03 §8.1).
  DsDensity get density => DsTheme.densityOf(this);
}
