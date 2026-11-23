import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/app/global_states/app_version_gate.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/env_banner.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';
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
    // Область «общее устройство» (03 §9.74, DS-100; ADR-115 п. 27): только в режиме планшета магазина.
    final bool sharedDevice = ref.watch(appModeProvider.select((AppMode mode) => mode == AppMode.kiosk));
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
      // Глобальные состояния поверх навигации: маркер окружения вне prod (EnvBanner, RM-C-008; в веб-демо его нет —
      // ADR-114 п. 9 (5), `AppConfig.envBannerCode`),
      // SCR-90 «Требуется обновление» / мягкий баннер версии (RM-C-015) и слой сессии (RM-D-009):
      // SCR-08 overlay (idle 30 мин, фон > 5 мин, Ctrl+L, UNLOCK_REQUIRED), StepUpDialog по 403 STEP_UP_REQUIRED,
      // SCR-90 C «Сессия завершена». Холодный старт — маршрут SCR-08 `/auth/unlock?mode=cold`, который
      // выбирает Splash (02 SCR-00.6; D_spec_questions SS-05, AU-05), поэтому coverColdStart: false.
      // Слой блокировки в сессии — SCR-08 фичи auth ([appLockScreen]): биометрия S/W, «Войти через Windows Hello» (W2)
      // и «Windows Hello» (W1), как на холодном старте (02 SCR-08.2 «idle — как cold», 09 §8.8; known_issues WEB-KI-39).
      // Настройки отображения SCR-42: размер текста (UI-42-025) и «Уменьшить анимации» (UI-42-007)
      // (третий источник reduce-motion 03 §11.1 — через `MediaQuery.disableAnimations`).
      // Фото товаров и категорий: сервер отдаёт путь `/images/{sha256}/{size}` без хоста (00_root.yaml `Image`) —
      // разрешается от `API_BASE_URL` (ProductImageBase).
      // Ввод на общем устройстве: `PrivateInputScope` оборачивает Navigator — область получают все маршруты, нижние
      // листы и диалоги корневого навигатора; виджет стоит всегда (вне режима планшета — `enabled: false`), чтобы
      // смена режима не пересоздавала Navigator.
      builder: (context, child) => MediaQuery(
        data: displayMediaQuery(MediaQuery.of(context), display),
        child: PrivateInputScope(
          enabled: sharedDevice,
          child: ProductImageBase(
            baseUri: config.apiBaseUrl,
            child: EnvBanner(
              environmentCode: config.envBannerCode,
              child: AppVersionGate(
                child: SessionGate(
                  coverColdStart: false,
                  lockScreenBuilder: appLockScreen,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// SCR-08 `idle` в слое сессии (`SessionGate.lockScreenBuilder`): после простоя 30 мин (D-48), возврата из фона > 5 мин,
/// `Ctrl+L` и `UNLOCK_REQUIRED` — тот же вход, что на холодном старте: биометрия S/W, ключ Windows Hello без PIN (W2,
/// `POST /auth/unlock {method: hello_key}`), гейт W1, PIN (02 SCR-08.2, SCR-08.4; 09 §8.8). Планшет магазина слоя не
/// получает (блокировки у него нет), а порт биометрии в режиме планшета отвечает «нет» (09 BIO-037).
/// Над слоем нет навигатора: «Войти по номеру телефона», «Забыли PIN?» и «Войти по SMS» — [SessionController.leaveToPhoneLogin]
/// (G-1 уводит на SCR-01), «Сменить аккаунт» — [SessionController.logout], конец сессии сервером —
/// [SessionController.sessionEnded] (SCR-90 C показывает слой сессии). PIN-слой `SessionLockOverlay` остаётся
/// запасным (`lockScreenBuilder: null`, тесты слоя).
Widget appLockScreen(BuildContext context, SessionLockReason reason) => Consumer(
  builder: (BuildContext context, WidgetRef ref, Widget? _) {
    final SessionController session = ref.read(sessionControllerProvider.notifier);
    return UnlockSessionLayer(
      idleMinutes: ref.read(sessionPolicyProvider).idleLock.inMinutes,
      manual: reason == SessionLockReason.manual,
      lockCaption: reason == SessionLockReason.idle || reason == SessionLockReason.manual,
      host: UnlockLayerHost(
        leaveToPhone: (AuthEntryReason? r) => session.leaveToPhoneLogin(
          reason: switch (r) {
            AuthEntryReason.pinReset => SessionEndReason.pinReset,
            AuthEntryReason.pinLocked => SessionEndReason.pinLocked,
            _ => SessionEndReason.phoneLogin,
          },
        ),
        switchAccount: session.logout,
        sessionEnded: ({required bool deviceMismatch}) =>
            session.sessionEnded(SessionEndSignal(code: deviceMismatch ? 'DEVICE_MISMATCH' : 'SESSION_REVOKED')),
      ),
    );
  },
);

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
