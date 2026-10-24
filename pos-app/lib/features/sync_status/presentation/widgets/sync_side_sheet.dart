// SCR-43 на expanded/large для `seller`/`cashier`/`senior_seller` (02 SCR-43.2 «Expanded», SCR-43.6): по тапу
// `SyncIndicator` — side sheet 480 справа поверх текущего экрана (зоны A, B, C), URL не меняется; закрытие —
// крестик, `Esc`, клик вне панели; «Подробнее» → полный экран `/sync` (push, «Назад» — исходный экран).
// `admin`/`owner` и прочие классы окна открывают полный экран (FIX-EF-08).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';

/// Side sheet SCR-43 (краткий вид).
abstract final class SyncStatusSideSheet {
  /// Ширина панели (02 SCR-43.2: SS 480).
  static const width = 480.0;

  /// Ключ панели (тесты).
  static const Key sheetKey = Key('sync-side-sheet');

  /// Открывать ли SCR-43 панелью: expanded/large и роль без полного журнала по умолчанию.
  static bool applies(WindowClass windowClass, RoleCode? role) =>
      (windowClass == WindowClass.expanded || windowClass == WindowClass.large) &&
      (role == RoleCode.seller || role == RoleCode.cashier || role == RoleCode.seniorSeller);

  /// Открыть SCR-43: панелью ([applies]) или полным экраном `/sync`.
  static Future<void> open(BuildContext context, {required RoleCode? role}) {
    if (!applies(context.windowClass, role)) return context.push<void>('/sync');
    return show(context);
  }

  /// Панель 480 справа: краткий SCR-43 (зоны A, B, C) с крестиком и «Подробнее» ([onMore]).
  static Widget panel({VoidCallback? onMore}) => Builder(
    builder: (BuildContext context) => Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SizedBox(
        key: sheetKey,
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(color: context.colors.background, boxShadow: context.elevation.e3),
          child: Material(
            type: MaterialType.transparency,
            child: SyncStatusScreen(sheet: true, onMore: onMore),
          ),
        ),
      ),
    ),
  );

  /// Показать панель поверх текущего экрана (корневой навигатор, URL не меняется).
  static Future<void> show(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final GoRouter? router = GoRouter.maybeOf(context);
    return showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: l10n.ds_button_close,
      barrierColor: context.colors.overlay,
      transitionDuration: context.motion.of(const Duration(milliseconds: 250)),
      pageBuilder: (dialogContext, _, _) {
        void more() {
          Navigator.of(dialogContext).pop();
          if (router != null) unawaited(router.push<void>('/sync'));
        }

        return panel(onMore: router == null ? null : more);
      },
      transitionBuilder: (context, a, _, child) {
        final curved = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
          child: child,
        );
      },
    );
  }
}
