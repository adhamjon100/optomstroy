import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/app/global_states/app_version_gate.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/env_banner.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/session_ui/presentation/session_gate.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart'
    show DisplayPreferences, TextScaleOption;
import 'package:optomstroy/features/settings/settings_providers.dart' show displayPreferencesProvider;

/// Корневой виджет: `MaterialApp.router`, тема, локализация (06 §6.2).
class App extends ConsumerWidget {
  /// Создаёт корневой виджет.
  const App({super.key});

  /// Основной язык интерфейса (ru — шаблон ARB, 03 §16.1).
  static const Locale defaultLocale = Locale('ru');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // Мосты между фичами (билет регистрации auth → registration) живут всё время работы приложения.
    ref.watch(featureBridgesProvider);
    // Офлайн-кэш каталога и outbox (RM-E-009): планировщик создаётся с первым открытием БД пользователя
    // (`appDatabaseProvider`, app/di) и дальше живёт всё время работы приложения — выход/новый вход он
    // отслеживает сам (`onSignedOut` / `onSignedIn`). До входа таймеров синхронизации нет.
    if (ref.watch(appDatabaseProvider.select((db) => db != null))) ref.watch(syncSchedulerProvider);
    final DisplayPreferences display = ref.watch(displayPreferencesProvider);
    final AppConfig config = ref.watch(appConfigProvider);
    final environment = config.environment;
    return MaterialApp.router(
      routerConfig: router,
      // Название продукта не переводится (отдельного ключа ARB нет); заголовок окна Windows задаёт
      // windows/runner/main.cpp тем же текстом (responsive-spec R-5, ADR-112).
      title: 'Оптомстрой POS',
      theme: AppTheme.light(),
      themeMode: ThemeMode.light,
      locale: defaultLocale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      // Глобальные состояния поверх навигации: маркер окружения вне prod (EnvBanner, RM-C-008),
      // SCR-90 «Требуется обновление» / мягкий баннер версии (RM-C-015) и слой сессии (RM-D-009):
      // SCR-08 overlay (idle 30 мин, фон > 5 мин, Ctrl+L, UNLOCK_REQUIRED), StepUpDialog по 403 STEP_UP_REQUIRED,
      // SCR-90 C «Сессия завершена». Холодный старт — маршрут SCR-08 `/auth/unlock?mode=cold`, который
      // выбирает Splash (02 SCR-00.6; D_spec_questions SS-05, AU-05), поэтому coverColdStart: false.
      // Настройки отображения SCR-42: размер текста (UI-42-025) и «Уменьшить анимации» (UI-42-007)
      // (третий источник reduce-motion 03 §11.1 — через `MediaQuery.disableAnimations`).
      // Фото товаров и категорий: сервер отдаёт путь `/images/{sha256}/{size}` без хоста (00_root.yaml `Image`) —
      // разрешается от `API_BASE_URL` (ProductImageBase).
      builder: (context, child) => MediaQuery(
        data: displayMediaQuery(MediaQuery.of(context), display),
        child: ProductImageBase(
          baseUri: config.apiBaseUrl,
          child: EnvBanner(
            environmentCode: environment == AppEnvironment.prod ? null : environment.name,
            child: AppVersionGate(child: SessionGate(coverColdStart: false, child: child ?? const SizedBox.shrink())),
          ),
        ),
      ),
    );
  }
}

/// Предел масштаба текста при выбранном размере (02 UI-42-025): expanded/large — 1,3, compact/medium — 1,5.
double /* money-double: allow — масштаб текста */ maxTextScaleFor(WindowClass windowClass) => switch (windowClass) {
  WindowClass.expanded || WindowClass.large => 1.3,
  WindowClass.compact || WindowClass.medium => 1.5,
};

/// [base] с настройками отображения пользователя (02 SCR-42): размер текста UI-42-025 —
/// `TextScaler = max(системный, выбранный)`, clamp по классу окна ([maxTextScaleFor]); «Уменьшить анимации»
/// UI-42-007 — `disableAnimations`.
MediaQueryData displayMediaQuery(MediaQueryData base, DisplayPreferences display) {
  MediaQueryData data = base;
  if (display.textScale != TextScaleOption.system) {
    final double system = base.textScaler.scale(100) / 100; // money-double: allow — масштаб текста
    final double cap = maxTextScaleFor(DsBreakpoints.forWidth(base.size.width)); // money-double: allow — масштаб
    data = data.copyWith(textScaler: TextScaler.linear(math.min(math.max(system, display.textScale.factor), cap)));
  }
  if (display.reduceMotion && !base.disableAnimations) data = data.copyWith(disableAnimations: true);
  return data;
}
