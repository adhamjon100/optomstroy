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

/// Снекбар `AppSnackbar` (03 §9.48): плашка `inverseSurface`, радиус `md`, `elevation.2`,
/// паддинг 12/16, мин. высота 48; текст `body 14/400 onInverseSurface` (≤ 2 строки);
/// действие — `primaryContainer` на `inverseSurface` (14.58:1). Показ — [show]: 4 с
/// (8 с с действием или при screen reader), один на экране (новый заменяет старый).
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

  /// Длительность показа (03 §9.48 [ТИПОВО]).
  static Duration durationFor({required bool hasAction, required bool accessibleNavigation}) =>
      hasAction || accessibleNavigation ? const Duration(seconds: 8) : const Duration(seconds: 4);

  /// Показывает снекбар через `ScaffoldMessenger` (заменяя текущий).
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context, {
    required String message,
    AppSnackbarVariant variant = AppSnackbarVariant.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final bool a11y = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    final bool persistent = variant == AppSnackbarVariant.error && actionLabel != null;
    final bool compact = context.windowClass == WindowClass.compact;
    return messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        width: compact ? null : 480,
        margin: compact ? const EdgeInsets.fromLTRB(16, 0, 16, 8) : null,
        persist: persistent,
        duration: persistent
            ? const Duration(days: 1)
            : durationFor(hasAction: actionLabel != null, accessibleNavigation: a11y),
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
      AppSnackbarVariant.success => (Icons.check_circle_rounded, c.successContainer),
      AppSnackbarVariant.error => (Icons.error_rounded, c.errorContainer),
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
            if (icon.$1 != null) ...<Widget>[Icon(icon.$1, size: 20, color: icon.$2), const SizedBox(width: 12)],
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
