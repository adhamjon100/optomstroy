// SCR-50 Главный экран клиента (`/home?view=&sort=`, customer; 02 ч. E, ядро v1.9 §24.2; RM-E-017).
//
// Имя класса, путь файла и параметры конструктора фиксированы маршрутом (app/router/routes.dart, только
// path/query, без `$extra`; 06 §6.4). Содержимое (каталог клиента, «Мой кабинет», категории, недавние,
// корзина) — порт [customerHomeBodyProvider] фичи home, привязанный корнем к `CustomerHomeView` фичи
// catalog (EQ-FEF-07, EQ-HOME-01). Экран добавляет поведение корня ветки: Android — двойное «Назад»
// для выхода с подсказкой `home_back_to_exit` (02 SCR-50.11 [ТИПОВО]).
import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/home/home_providers.dart';

/// SCR-50 — Главный экран клиента.
class CustomerHomeScreen extends ConsumerStatefulWidget {
  const CustomerHomeScreen({this.view, this.sort, super.key});

  /// ID экрана по 02 §4.1.
  static const String screenId = 'SCR-50';

  /// Корневой ключ экрана (сохранён с этапа основы маршрутов).
  static const Key screenKey = ValueKey<String>('stub-$screenId');

  /// Окно второго нажатия «Назад» для выхода.
  static const Duration exitWindow = Duration(seconds: 2);

  /// Вид: `grid|list|compact`.
  final String? view;

  /// Сортировка — значение API.
  final String? sort;

  @override
  ConsumerState<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends ConsumerState<CustomerHomeScreen> {
  DateTime? _lastBack;

  void _onBack(bool didPop, Object? _) {
    if (didPop) {
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? last = _lastBack;
    if (last != null && now.difference(last) <= CustomerHomeScreen.exitWindow) {
      _lastBack = null;
      unawaited(SystemNavigator.pop());
      return;
    }
    _lastBack = now;
    AppSnackbar.show(context, message: AppLocalizations.of(context).home_back_to_exit);
  }

  @override
  Widget build(BuildContext context) {
    final CustomerHomeBodyBuilder? body = ref.watch(customerHomeBodyProvider);
    final Widget content =
        body?.call(context, CustomerHomeArgs(view: widget.view, sort: widget.sort)) ??
        // Без привязки корня — пустой фон (без бесконечной анимации: экран не «ждёт» данных).
        Scaffold(backgroundColor: context.colors.background);
    return PopScope<Object?>(
      key: CustomerHomeScreen.screenKey,
      canPop: defaultTargetPlatform != TargetPlatform.android,
      onPopInvokedWithResult: _onBack,
      child: content,
    );
  }
}
