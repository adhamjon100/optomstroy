// Решение SCR-00 «куда дальше» (02 SCR-00.6; D-48; ядро §17.2, §24.2).
//
// Решение для гостя и `staff` — локальное, без сети (NFR-PERF-005): нет refresh-токена → SCR-01;
// `pending_activation` → SCR-07; `staff` (любая платформа) или `customer` с PIN/биометрией →
// SCR-08 `cold`; `customer` без PIN и биометрии → SCR-50; кэша профиля нет → SCR-08 `cold`
// (безопасный вариант, строка 9). Снимок даёт [splashSnapshotProvider]; по умолчанию он
// строится из `core/session` (`sessionStatusProvider`), полный снимок (refresh + кэш профиля
// `app_meta.profile_*`) подставляет SessionController (RM-D-009) переопределением провайдера.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/session/session_status.dart';

/// Куда ведёт Splash.
enum SplashDestination {
  /// SCR-01 `/auth/phone`.
  phone('/auth/phone'),

  /// SCR-08 `/auth/unlock?mode=cold`.
  unlock('/auth/unlock?mode=cold'),

  /// SCR-07 `/pending-activation`.
  pendingActivation('/pending-activation'),

  /// SCR-50 `/home` (каталог клиента — заглушка до RM-E).
  customerHome('/home');

  const SplashDestination(this.location);

  /// Адрес маршрута (граф маршрутов ядра R0 §9 / app/router/routes.dart).
  final String location;
}

/// Тип пользователя из кэша профиля (без ПДн).
enum SplashUserKind { staff, customer }

/// Что известно на устройстве при холодном старте (без телефона и ФИО).
final class SplashSnapshot {
  const SplashSnapshot({
    required this.hasSession,
    this.kind,
    this.pendingActivation = false,
    this.pinSet = false,
    this.biometricEnabled = false,
  });

  /// Нет refresh-токена.
  static const SplashSnapshot guest = SplashSnapshot(hasSession: false);

  /// Refresh-токен в secure storage.
  final bool hasSession;

  /// `null` — кэша профиля нет.
  final SplashUserKind? kind;
  final bool pendingActivation;
  final bool pinSet;
  final bool biometricEnabled;

  @override
  String toString() => 'SplashSnapshot(session: $hasSession, kind: ${kind?.name})';
}

/// Решение по строкам 3–6, 9 таблицы SCR-00.6 (первая сработавшая).
SplashDestination decideSplash(SplashSnapshot s) {
  if (!s.hasSession) {
    return SplashDestination.phone;
  }
  if (s.pendingActivation) {
    return SplashDestination.pendingActivation;
  }
  return switch (s.kind) {
    SplashUserKind.staff => SplashDestination.unlock,
    SplashUserKind.customer when s.pinSet || s.biometricEnabled => SplashDestination.unlock,
    SplashUserKind.customer => SplashDestination.customerHome,
    // Кэша профиля нет — SCR-08 `cold` (безопасный вариант, строка 9).
    null => SplashDestination.unlock,
  };
}

/// Снимок для Splash. Переопределяется SessionController (RM-D-009) полным снимком.
final splashSnapshotProvider = FutureProvider<SplashSnapshot>((ref) async {
  final SessionStatus status = await ref.watch(sessionStatusProvider.future);
  return switch (status) {
    SessionStatus.authenticated => const SplashSnapshot(hasSession: true),
    SessionStatus.unauthenticated || SessionStatus.unknown => SplashSnapshot.guest,
  };
});
