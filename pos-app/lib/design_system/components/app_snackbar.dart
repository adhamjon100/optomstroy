import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `AppSnackbar` (03 §9.48).
enum AppSnackbarVariant {
  /// Без иконки.
  info,

  /// `check_circle` `successContainer`.
  success,

  /// `error` `errorContainer`; с действием «Повторить» не исчезает по таймеру.
  error,
}

/// Размещение `AppSnackbar` на medium и шире (03 §9.48, редакция 1.10).
enum AppSnackbarPlacement {
  /// По умолчанию: compact — во всю ширину над нижним краем (поля 16), шире — по центру, ширина 480.
  auto,

  /// Тост внизу справа (прототип 2026-10-29, ADR-112): поля справа и снизу 24, ширина ≤ 360. На compact — как [auto].
  bottomEnd,
}

/// Область показа снекбаров над занятой частью окна (03 §9.48): drawer корзины 420 справа ставит над своим
/// `Scaffold` во всё окно (свой `ScaffoldMessenger`) — снекбары корзины видны и нажимаются над затемнением, а
/// [AppSnackbar.show] считает поля по свободной ширине, а не фиксированную ширину 480 от окна.
///
/// * Слева от drawer свободно не меньше [minSideWidth] — снекбар у левого края drawer (поля 24), ширина — до 480
///   (тост — до 360), но не шире свободной части без полей; кнопки drawer он не перекрывает.
/// * Иначе (узкий medium) — внутри drawer над закреплённым низом: поля 16 по бокам, снизу — [bottomInset] + 8
///   (высота итогов и кнопок, её сообщает `CartPanel`).
class AppSnackbarRegion extends InheritedWidget {
  /// Создаёт область.
  const AppSnackbarRegion({super.key, required this.endInset, this.bottomInset, required super.child});

  /// Ширина занятой справа части окна (drawer), lp.
  final double endInset;

  /// Высота закреплённого низа drawer (итоги и кнопки); `null` — 0.
  final ValueNotifier<double>? bottomInset;

  /// Свободная ширина слева от drawer, начиная с которой снекбар стоит снаружи drawer.
  static const double minSideWidth = 360;

  /// Ближайшая область или `null` (снекбар окна).
  static AppSnackbarRegion? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<AppSnackbarRegion>();

  @override
  bool updateShouldNotify(AppSnackbarRegion oldWidget) =>
      oldWidget.endInset != endInset || oldWidget.bottomInset != bottomInset;
}

/// Снекбар `AppSnackbar` (03 §9.48): плашка `inverseSurface`, радиус `md`, `elevation.2`,
/// паддинг 12/16, мин. высота 48; текст `body 14/400 onInverseSurface` (≤ 2 строки);
/// действие — `primaryContainer` на `inverseSurface` (14.58:1). Показ — [show]: 4 с
/// (8 с с действием или при screen reader), один на экране (новый заменяет старый). Тост ([show] с `brief`) —
/// 2 с (8 с при screen reader), обычно [AppSnackbarPlacement.bottomEnd].
class AppSnackbar extends StatelessWidget {
  /// Создаёт содержимое снекбара.
  const AppSnackbar({
    super.key,
    required this.message,
    this.variant = AppSnackbarVariant.info,
    this.actionLabel,
    this.onAction,
    this.actionLoading = false,
    this.onClose,
  });

  /// Текст.
  final String message;

  /// Вариант.
  final AppSnackbarVariant variant;

  /// Действие («Отменить», «Открыть», «Повторить»).
  final String? actionLabel;

  /// Действие.
  final VoidCallback? onAction;

  /// «Повторить» выполняется → спиннер 16 вместо текста.
  final bool actionLoading;

  /// Крестик (для ошибок).
  final VoidCallback? onClose;

  /// Длительность показа (03 §9.48 [ТИПОВО]); [brief] — тост «Добавлено: …» (2 с; 8 с при screen reader).
  static Duration durationFor({required bool hasAction, required bool accessibleNavigation, bool brief = false}) {
    if (hasAction || accessibleNavigation) {
      return const Duration(seconds: 8);
    }
    return brief ? const Duration(seconds: 2) : const Duration(seconds: 4);
  }

  /// Ширина снекбара на medium и шире.
  static const double width = 480;

  /// Наибольшая ширина тоста ([AppSnackbarPlacement.bottomEnd]).
  static const double toastMaxWidth = 360;

  /// Поля тоста от правого и нижнего края.
  static const double toastInset = 24;

  /// Ключ значка успеха (зелёный круг с галочкой; тесты).
  static const Key successIconKey = ValueKey<String>('app-snackbar-success-icon');

  /// Круг значка успеха: `success`, осветлённый на 30 % к `successContainer` (≈ #529B76, 5.0:1 к `inverseSurface`).
  static Color successCircle(DsColors c) => Color.lerp(c.success, c.successContainer, .3)!;

  /// Поля снекбара: compact — во всю ширину; [AppSnackbarRegion] — по свободной части окна; тост — внизу справа;
  /// иначе — `null` (по центру, ширина [width]).
  static EdgeInsets? marginFor({
    required double windowWidth,
    required WindowClass windowClass,
    required AppSnackbarPlacement placement,
    AppSnackbarRegion? region,
  }) {
    final double maxWidth = placement == AppSnackbarPlacement.bottomEnd ? toastMaxWidth : width;
    if (region != null) {
      final double free = math.max(0, windowWidth - region.endInset);
      if (free >= AppSnackbarRegion.minSideWidth) {
        final double right = region.endInset + toastInset;
        final double w = math.min(maxWidth, free - 2 * toastInset);
        return EdgeInsets.fromLTRB(math.max(toastInset, windowWidth - right - w), 0, right, toastInset);
      }
      final double bottom = (region.bottomInset?.value ?? 0) + 8;
      return EdgeInsets.fromLTRB(free + 16, 0, 16, bottom);
    }
    if (windowClass == WindowClass.compact) {
      return const EdgeInsets.fromLTRB(16, 0, 16, 8);
    }
    if (placement == AppSnackbarPlacement.bottomEnd) {
      final double w = math.min(toastMaxWidth, windowWidth - 2 * toastInset);
      return EdgeInsets.fromLTRB(math.max(toastInset, windowWidth - toastInset - w), 0, toastInset, toastInset);
    }
    return null;
  }

  /// Показывает снекбар через `ScaffoldMessenger` (заменяя текущий).
  ///
  /// [brief] — короткий тост (2 с; 8 с при screen reader); [placement] — размещение на medium и шире. Внутри
  /// [AppSnackbarRegion] поля считаются по свободной части окна (drawer корзины).
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context, {
    required String message,
    AppSnackbarVariant variant = AppSnackbarVariant.info,
    String? actionLabel,
    VoidCallback? onAction,
    bool brief = false,
    AppSnackbarPlacement placement = AppSnackbarPlacement.auto,
  }) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final bool a11y = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    final bool persistent = variant == AppSnackbarVariant.error && actionLabel != null;
    final EdgeInsets? margin = marginFor(
      windowWidth: MediaQuery.sizeOf(context).width,
      windowClass: context.windowClass,
      placement: placement,
      region: AppSnackbarRegion.maybeOf(context),
    );
    return messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        width: margin == null ? width : null,
        margin: margin,
        persist: persistent,
        duration: persistent
            ? const Duration(days: 1)
            : durationFor(hasAction: actionLabel != null, accessibleNavigation: a11y, brief: brief),
        content: AppSnackbar(
          message: message,
          variant: variant,
          actionLabel: actionLabel,
          onAction: onAction == null
              ? null
              : () {
                  messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.action);
                  onAction();
                },
          onClose: variant == AppSnackbarVariant.error ? messenger.hideCurrentSnackBar : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final (IconData?, Color) icon = switch (variant) {
      AppSnackbarVariant.info => (null, c.onInverseSurface),
      AppSnackbarVariant.success => (Icons.check_rounded, c.onSuccess),
      AppSnackbarVariant.error => (Icons.error_rounded, c.errorContainer),
    };
    // Успех (прототип 2026-10-29, тост «Добавлено»): зелёный круг 18 с белой галочкой. Круг — `success`, осветлённый
    // на 30 % к `successContainer` (≈ 5:1 к `inverseSurface`; белая галочка на нём ≥ 3:1).
    final Widget? glyph = switch (variant) {
      AppSnackbarVariant.success => Container(
        key: successIconKey,
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: successCircle(c), shape: BoxShape.circle),
        child: Icon(icon.$1, size: 14, color: icon.$2),
      ),
      _ when icon.$1 != null => Icon(icon.$1, size: 20, color: icon.$2),
      _ => null,
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsetsDirectional.only(start: 16, end: 8, top: 4, bottom: 4),
        decoration: BoxDecoration(
          color: c.inverseSurface,
          borderRadius: BorderRadius.all(context.radii.md),
          boxShadow: context.elevation.e2,
        ),
        child: Row(
          children: <Widget>[
            if (glyph != null) ...<Widget>[glyph, const SizedBox(width: 12)],
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body.copyWith(color: c.onInverseSurface),
                ),
              ),
            ),
            if (actionLabel != null) _Action(label: actionLabel!, onTap: onAction, loading: actionLoading),
            if (onClose != null) _Close(label: AppLocalizations.of(context).ds_button_close, onTap: onClose!),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.label, required this.onTap, required this.loading});

  final String label;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: loading ? null : onTap,
        builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
          minHeight: 44,
          child: DsFocusRing(
            visible: s.focused,
            borderRadius: radius,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: radius,
                color: s.pressed || s.hovered ? c.onInverseSurface.withValues(alpha: 0.12) : Colors.transparent,
              ),
              child: loading
                  ? AppProgress.circular(size: 16, color: c.onInverseSurface)
                  : Text(
                      label,
                      style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryContainer),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Close extends StatelessWidget {
  const _Close({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
          child: DsFocusRing(
            visible: s.focused,
            circle: true,
            child: Icon(Icons.close_rounded, size: 20, color: c.onInverseSurface),
          ),
        ),
      ),
    );
  }
}
