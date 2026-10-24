// «Назад» на корне каталога — выход из приложения по двойному нажатию (02 SCR-10.11, SCR-50.11, SCR-50.12):
// Android — первое «Назад» показывает подсказку `home_back_to_exit` («Нажмите ещё раз для выхода»), второе в
// течение 2 с закрывает приложение (`SystemNavigator.pop`). На прочих платформах системного «Назад» нет —
// поведение не меняется.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';

/// Двойное «Назад» для выхода с корня (SCR-10, SCR-50).
class BackToExitScope extends StatefulWidget {
  const BackToExitScope({super.key, required this.child, this.enabled = true, this.platform, this.exit});

  final Widget child;

  /// `false` — не корень (поиск, категория): «Назад» как обычно.
  final bool enabled;

  /// Платформа (по умолчанию — `defaultTargetPlatform`); перехват только на Android.
  final TargetPlatform? platform;

  /// Выход из приложения (по умолчанию — `SystemNavigator.pop`); подменяется в тестах.
  final Future<void> Function()? exit;

  /// Окно второго нажатия.
  static const Duration window = Duration(seconds: 2);

  @override
  State<BackToExitScope> createState() => _BackToExitScopeState();
}

class _BackToExitScopeState extends State<BackToExitScope> {
  DateTime? _firstAt;

  bool get _active => widget.enabled && (widget.platform ?? defaultTargetPlatform) == TargetPlatform.android;

  void _onBack() {
    final DateTime now = DateTime.now();
    final DateTime? first = _firstAt;
    if (first != null && now.difference(first) <= BackToExitScope.window) {
      _firstAt = null;
      unawaited((widget.exit ?? SystemNavigator.pop)());
      return;
    }
    _firstAt = now;
    AppSnackbar.show(context, message: AppLocalizations.of(context).home_back_to_exit);
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !_active,
    onPopInvokedWithResult: (bool didPop, Object? _) {
      if (!didPop && _active) _onBack();
    },
    child: widget.child,
  );
}
