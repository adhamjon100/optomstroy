// Решение SCR-00 «куда дальше» (02 SCR-00.6; D-48; ядро §17.2, §24.2).
//
// Решение для гостя и `staff` — локальное, без сети (NFR-PERF-005): нет refresh-токена → SCR-01;
// `pending_activation` → SCR-07; `staff` (любая платформа) или `customer` с PIN/биометрией →
// SCR-08 `cold`; `customer` без PIN и биометрии → SCR-50; кэша профиля нет → SCR-08 `cold`
// (безопасный вариант, строка 9). Снимок даёт [splashSnapshotProvider]; по умолчанию он
// строится из `core/session` (`sessionStatusProvider`), полный снимок (refresh + кэш профиля
// `app_meta.profile_*`) подставляет SessionController (RM-D-009) переопределением провайдера.
// Планшет магазина (02 SCR-00.6 строка 1а, версия 1.27; P-002 §8.2 п. 8, ADR-115): признак планшета на устройстве
// срабатывает раньше строк 2–9 — SCR-51 `/kiosk` без SCR-08 с сессией и без неё (без сессии SCR-51 сам показывает
// «Планшет нужно подключить заново», G-0a). Маршрут решает признак планшета, а не кэш профиля; режимы сотрудников и
// покупателя не меняются (10 KIOSK-029).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_controller.dart';
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
  customerHome('/home'),

  /// SCR-51 `/kiosk` — режим «Планшет магазина» (строка 1а SCR-00.6; маршрут — `app/router/kiosk_routes.dart`).
  kiosk('/kiosk');

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
    this.kioskTablet = false,
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

  /// Признак планшета магазина на устройстве (строка 1а SCR-00.6): сессия технического пользователя `kind=kiosk`
  /// или сохранённый признак без сессии. Только факт, без идентификатора и имени планшета.
  final bool kioskTablet;

  @override
  String toString() => 'SplashSnapshot(session: $hasSession, kind: ${kind?.name}, kiosk: $kioskTablet)';
}

/// Решение по строкам 1а, 3–6, 9 таблицы SCR-00.6 (первая сработавшая).
SplashDestination decideSplash(SplashSnapshot s) {
  // Строка 1а: признак планшета — раньше строк 2–9 (и раньше «нет refresh-токена → SCR-01»).
  if (s.kioskTablet) {
    return SplashDestination.kiosk;
  }
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
///
/// Признак планшета по умолчанию — вид субъекта восстановленной сессии (`kind=kiosk`, `SessionState.userKind`).
final splashSnapshotProvider = FutureProvider<SplashSnapshot>((ref) async {
  final SessionStatus status = await ref.watch(sessionStatusProvider.future);
  final bool kioskTablet = ref.watch(sessionControllerProvider.select((s) => s.userKind == UserKind.kiosk));
  return switch (status) {
    SessionStatus.authenticated => SplashSnapshot(hasSession: true, kioskTablet: kioskTablet),
    SessionStatus.unauthenticated || SessionStatus.unknown => SplashSnapshot.guest,
  };
});
