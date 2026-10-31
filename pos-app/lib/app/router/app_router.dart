import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/guards/auth_guard.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/gallery/ds_gallery_screen.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_router.g.dart';

/// Главный экран режима (06 §6.4, roleGuard).
String homeLocationFor(AppMode mode) => switch (mode) {
  AppMode.seller || AppMode.admin => const CatalogRoute().location,
  AppMode.cashier => const CashierRoute().location,
  // owner — SCR-48 (navigation.md §2.3, §14.7).
  AppMode.owner => const ReportsRoute().location,
  AppMode.customer => const HomeRoute().location,
};

/// Режим клиента-покупателя включён (`CUSTOMER_SELF_SERVICE`, по умолчанию `true` — ядро v1.9 §24.2).
///
/// Источник по 08 — `GET /settings/public` `features.customerSelfService`; провайдера публичных
/// настроек в каркасе ещё нет (RM-D-015), поэтому — флаг сборки `FEATURE_CUSTOMER_SELF_SERVICE`
/// (как `adminCustomerSelfServiceProvider`). Переопределяется в тестах.
final customerSelfServiceEnabledProvider = Provider<bool>(
  (ref) => ref.watch(appConfigProvider).features[FeatureFlag.customerSelfService] ?? true,
);

/// Флаги функций этапа G для guard-ов (RM-G-005, RM-G-013): заявки на возврат и оплата долга без заказа.
///
/// По умолчанию — [RouteFeatures.defaults] (возвраты не закрыты, оплата долга без заказа закрыта — R1, Q-152).
/// Композиционный корень (`app/di/overrides.dart`) подставляет флаги `GET /settings/public` через
/// [routeFeaturesFrom] (как `customerSelfServiceEnabledProvider`). Переопределяется в тестах.
final routeFeaturesProvider = Provider<RouteFeatures>((ref) => RouteFeatures.defaults);

/// [RouteFeatures] из `features` публичных настроек: `returnsFromPos` учитывается только из ответа сервера (до него
/// маршрут возврата не закрывается — сервер ответит сам); `debtPaymentsFromPos` — fail-closed (`false` до ответа).
RouteFeatures routeFeaturesFrom(PublicFeatureFlags flags) => RouteFeatures(
  returnsEnabled: flags.fromServer ? flags.returnsFromPos : null,
  debtPaymentsFromPos: flags.debtPaymentsFromPos,
);

/// Глобальный redirect: authGuard (сессия; G-5 — блокировка холодного старта [lock]), затем roleGuard (режим и роль,
/// флаг самообслуживания клиента, флаги функций этапа G).
String? appRedirect({
  required SessionStatus status,
  required Uri uri,
  required AppMode mode,
  required bool customerSelfService,
  RoleCode? role,
  SessionEndReason? endReason,
  SessionLockReason? lock,
  RouteFeatures features = RouteFeatures.defaults,
}) {
  final home = homeLocationFor(mode);
  final auth = authRedirect(status: status, uri: uri, homeLocation: home, endReason: endReason, lock: lock);
  if (auth != null || status != SessionStatus.authenticated || isPublicPath(uri.path)) return auth;
  return roleRedirect(
    mode: mode,
    uri: uri,
    homeLocation: home,
    customerSelfService: customerSelfService,
    role: role,
    features: features,
  );
}

/// Снекбар G-7, сопровождающий перенаправление [appRedirect] (только для аутентифицированной сессии,
/// после authGuard), или `null`.
RoleGuardNotice? appRedirectNotice({
  required SessionStatus status,
  required Uri uri,
  required AppMode mode,
  required bool customerSelfService,
  RoleCode? role,
  SessionLockReason? lock,
  RouteFeatures features = RouteFeatures.defaults,
}) {
  final home = homeLocationFor(mode);
  if (status != SessionStatus.authenticated || isPublicPath(uri.path)) return null;
  if (authRedirect(status: status, uri: uri, homeLocation: home, lock: lock) != null) return null;
  return roleRedirectNotice(
    mode: mode,
    uri: uri,
    homeLocation: home,
    customerSelfService: customerSelfService,
    role: role,
    features: features,
  );
}

/// Текст снекбара G-7 (03 §16.7: `global_role_forbidden`, `global_payment_cashier_only`).
String roleGuardNoticeText(AppLocalizations l10n, RoleGuardNotice notice) => switch (notice) {
  RoleGuardNotice.roleForbidden => l10n.global_role_forbidden,
  RoleGuardNotice.paymentCashierOnly => l10n.global_payment_cashier_only,
};

/// G-11 (navigation.md §4.1, D-42): `/scan` на платформе без камеры (Windows) — переход не выполняется,
/// пользователь остаётся на исходном экране со снекбаром про аппаратный сканер. Прямой вход на `/scan`
/// без исходного экрана (deep link, восстановление) не блокируется: SCR-17 показывает `EmptyState.noCamera`.
bool blocksScanWithoutCamera({
  required Uri current,
  required Uri next,
  required bool cameraSupported,
  required bool authenticated,
}) {
  if (cameraSupported || !authenticated || next.path != '/scan') return false;
  return current.path != next.path;
}

/// Показывает снекбар после кадра, если над [context] есть `ScaffoldMessenger` и локализация.
void _showGuardSnackbar(BuildContext context, String Function(AppLocalizations l10n) message) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted || ScaffoldMessenger.maybeOf(context) == null) return;
    final l10n = Localizations.of<AppLocalizations>(context, AppLocalizations);
    if (l10n == null) return;
    AppSnackbar.show(context, message: message(l10n));
  });
}

/// Состояние, по которому guards решают на момент навигации (читается из провайдеров в [appRouter]).
typedef GuardInputs = ({
  SessionStatus status,
  AppMode mode,
  bool customerSelfService,
  RoleCode? role,
  SessionEndReason? endReason,
  SessionLockReason? lock,
  bool cameraSupported,
});

/// Глобальный redirect роутера: [appRedirect]; перенаправление по G-7 сопровождается снекбаром
/// «Раздел недоступен для вашей роли» / «Приём оплаты выполняет кассир» (navigation.md §4.1, §4.3).
String? guardRedirect(
  BuildContext context,
  GoRouterState state,
  GuardInputs g, {
  RouteFeatures features = RouteFeatures.defaults,
}) {
  final target = appRedirect(
    status: g.status,
    uri: state.uri,
    mode: g.mode,
    customerSelfService: g.customerSelfService,
    role: g.role,
    endReason: g.endReason,
    lock: g.lock,
    features: features,
  );
  if (target == null) return null;
  final notice = appRedirectNotice(
    status: g.status,
    uri: state.uri,
    mode: g.mode,
    customerSelfService: g.customerSelfService,
    role: g.role,
    lock: g.lock,
    features: features,
  );
  if (notice != null) _showGuardSnackbar(context, (l10n) => roleGuardNoticeText(l10n, notice));
  return target;
}

/// `onEnter` роутера — G-11: `/scan` без камеры блокируется, пользователь остаётся на исходном экране
/// со снекбаром про аппаратный сканер (текст — `catalog_scanner_hid_hint`, тот же, что у кнопки сканера
/// SCR-10 на Windows, UI-10-044).
OnEnterResult guardOnEnter(BuildContext context, GoRouterState current, GoRouterState next, GuardInputs g) {
  final blocked = blocksScanWithoutCamera(
    current: current.uri,
    next: next.uri,
    cameraSupported: g.cameraSupported,
    authenticated: g.status == SessionStatus.authenticated,
  );
  if (!blocked) return const Allow();
  return Block.then(() => _showGuardSnackbar(context, (l10n) => l10n.catalog_scanner_hid_hint));
}

/// Единственный `GoRouter` приложения: маршруты `$appRoutes` (routes.dart) и
/// глобальный redirect (guards/). Пересчитывает redirect при смене сессии/режима.
@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final refresh = ValueNotifier<int>(0);
  ref
    ..listen(sessionStatusProvider, (_, _) => refresh.value++)
    // G-5: снятие/появление блокировки холодного старта пересчитывает redirect (SCR-08 `cold` ↔ рабочий маршрут).
    ..listen(sessionLockProvider.select((l) => l == SessionLockReason.coldStart), (_, _) => refresh.value++)
    ..listen(appModeProvider, (_, _) => refresh.value++)
    ..listen(authSessionProvider.select((s) => s.profile.primaryRole), (_, _) => refresh.value++)
    ..listen(customerSelfServiceEnabledProvider, (_, _) => refresh.value++)
    ..listen(routeFeaturesProvider, (_, _) => refresh.value++);

  GuardInputs inputs() => (
    status: ref.read(sessionStatusProvider).value ?? SessionStatus.unknown,
    mode: ref.read(appModeProvider),
    customerSelfService: ref.read(customerSelfServiceEnabledProvider),
    role: ref.read(authSessionProvider).profile.primaryRole,
    endReason: ref.read(sessionEndReasonProvider),
    lock: ref.read(sessionLockProvider),
    cameraSupported: ref.read(cameraScannerSupportedProvider),
  );

  final router = GoRouter(
    initialLocation: const SplashRoute().location,
    // `if (kDebugMode)` на месте вызова: в release-AOT ветка выбрасывается вместе с кодом витрины.
    routes: <RouteBase>[...$appRoutes, if (kDebugMode) ...devRoutes()],
    refreshListenable: refresh,
    // G-11: `/scan` без камеры — остаться на исходном экране + снекбар (переход блокируется до redirect).
    // `onEnter` делает разбор каждого перехода асинхронным, поэтому подключается только на платформе без
    // камеры (Windows, D-42); на Android/iOS guard не нужен и разбор остаётся синхронным.
    onEnter: ref.read(cameraScannerSupportedProvider)
        ? null
        : (context, current, next, router) => guardOnEnter(context, current, next, inputs()),
    redirect: (context, state) {
      // Витрина дизайн-системы — служебный экран debug-сборки, без сессии и guard-ов (RM-C-003).
      if (kDebugMode && state.uri.path == DsGalleryScreen.routePath) return null;
      return guardRedirect(context, state, inputs(), features: ref.read(routeFeaturesProvider));
    },
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
}

/// Служебные маршруты только debug-сборки: `/dev/gallery` — витрина дизайн-системы (RM-C-003).
/// В release (`kDebugMode == false`) список пуст — маршрута нет.
List<RouteBase> devRoutes({bool debug = kDebugMode}) => <RouteBase>[
  if (debug) GoRoute(path: DsGalleryScreen.routePath, builder: (context, state) => const DsGalleryScreen()),
];
