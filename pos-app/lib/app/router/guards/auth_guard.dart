import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';

/// Маршруты, доступные без сессии (гость, R0 §9).
const List<String> publicPathPrefixes = <String>[
  '/splash',
  '/auth/phone',
  '/auth/otp',
  '/auth/unlock',
  '/register',
  '/pending-activation',
];

/// `true`, если [path] не требует сессии.
bool isPublicPath(String path) => publicPathPrefixes.any((prefix) => path == prefix || path.startsWith('$prefix/'));

/// Глобальный redirect: Splash и authGuard (06 §6.4).
///
/// - сессия ещё восстанавливается → `/splash`;
/// - G-0a (navigation.md §4.1; P-002 §8.2 п. 8, §9; ADR-115): признак планшета магазина на устройстве без сессии
///   ([kioskHold]: срок сессии планшета вышел — `401 SESSION_REVOKED`; или SCR-51 «Планшет отключён» ещё на экране)
///   → любой путь, в том числе гостевые `/auth/*`, `/register*`, `/pending-activation`, `/kiosk/checkout`,
///   `/kiosk/done`, → `/kiosk`; на `/kiosk` — остаться. Проверка — после G-0 и до G-1: иначе G-1 увёл бы планшет с
///   истёкшей сессией на экран входа. `/splash` после проверки сессии ведёт SCR-00 (строка 1а → `/kiosk`). После
///   `401 KIOSK_REVOKED` и аварийного выхода признака нет — G-0a не срабатывает, действует G-1 без `returnTo`;
/// - на `/splash` после восстановления решение принимает SplashScreen (02 SCR-00.6: staff → SCR-08 `cold`,
///   customer без PIN → SCR-50, гость → SCR-01, признак планшета → SCR-51 — строка 1а; ANIM-001 не обрывается —
///   D_spec_questions AU-05); исключение — сессия планшета (G-15 ниже);
/// - нет сессии и маршрут защищён → `/auth/phone?returnTo=<адрес>`; после явного выхода ([endReason]
///   `logout` / `logoutAll`) — без `returnTo`: стек очищен, следующий вход не продолжает путь прежнего
///   пользователя (09 §8.6, 02 SCR-42.6; EQ-DREST-17);
/// - G-15 (navigation.md §4.1; P-002 §9, ADR-115): сессия технического пользователя планшета ([kioskSession],
///   `kind=kiosk`) на любом пути вне `{/kiosk, /kiosk/checkout, /kiosk/done}` → `/kiosk` (без снекбара). Проверка —
///   здесь, а не в roleGuard: `appRedirect` пропускает публичные пути мимо roleGuard, поэтому `/auth/*`, `/register*`,
///   `/pending-activation` и `/splash` после проверки сессии ловит только authGuard (T-KIOSK-045). Стоит до G-5, и
///   G-5 к планшету не применяется (на `/kiosk*` — остаться): блокировки холодного старта и SCR-08 у планшета нет (PIN
///   нет). Вторая половина G-15 — `/kiosk*` для сотрудника и `customer` — в roleGuard (`guards/role_guard.dart`);
/// - G-5 (navigation.md §4.1): сессия есть, но заблокирована холодным стартом ([lock] `coldStart`), а маршрут
///   защищён → `/auth/unlock?mode=cold&from=<адрес>` — SCR-08 `cold`, после разблокировки `go(from)`. Так
///   холодный старт сразу на внутреннем адресе (deep link; веб-демо: F5 на `#/cashier`, ADR-113) не минует
///   SCR-08: слой сессии холодный старт не закрывает (`SessionGate(coverColdStart: false)`), а запросы ждут
///   разблокировки. Публичные маршруты (SCR-01 «Войти по номеру телефона» с SCR-08) не перенаправляются.
///
/// [homeLocation] оставлен для совместимости вызова (главный экран режима выбирают Splash и экраны входа).
String? authRedirect({
  required SessionStatus status,
  required Uri uri,
  required String homeLocation,
  SessionEndReason? endReason,
  SessionLockReason? lock,
  bool kioskSession = false,
  bool kioskHold = false,
}) {
  final path = uri.path;
  final splash = const SplashRoute().location;
  if (status == SessionStatus.unknown) {
    return path == splash ? null : splash;
  }
  final authenticated = status == SessionStatus.authenticated;
  // G-0a: признак планшета без сессии — только `/kiosk` «Подключите заново» (после G-0, до G-1); экрана входа нет.
  if (!authenticated && kioskHold) {
    if (path == splash || path == KioskPaths.showcase) return null;
    return KioskPaths.showcase;
  }
  // G-15: сессия планшета — только маршруты режима (после G-0, до G-1/G-5); G-5 к планшету не применяется.
  if (authenticated && kioskSession) {
    return isKioskModePath(path) ? null : KioskPaths.showcase;
  }
  if (path == splash) {
    return null;
  }
  if (!authenticated && !isPublicPath(path)) {
    // Конец режима планшета — как явный выход: SCR-01 без `returnTo` (путь `/kiosk*` другому пользователю не нужен);
    // после выхода без связи — с подсказкой `kiosk_exit_offline_hint` (02 SCR-51 UI-51-017 п. 3).
    if (endReason == SessionEndReason.kioskExitedOffline) return kioskOfflineExitLocation;
    final explicitLogout =
        endReason == SessionEndReason.logout ||
        endReason == SessionEndReason.logoutAll ||
        (endReason?.isKiosk ?? false);
    return AuthPhoneRoute(returnTo: explicitLogout ? null : uri.toString()).location;
  }
  if (authenticated && lock == SessionLockReason.coldStart && !isPublicPath(path)) {
    return coldUnlockLocation(uri);
  }
  return null;
}

/// SCR-01 после аварийного выхода планшета без связи: баннер `kiosk_exit_offline_hint` (`AuthEntryReason.kioskExitOffline`).
const String kioskOfflineExitLocation = '/auth/phone?reason=kiosk_exit_offline';

/// Адрес SCR-08 `cold` с возвратом на [from] (G-5: `/auth/unlock?mode=cold&from=<адрес>`).
String coldUnlockLocation(Uri from) =>
    Uri(path: '/auth/unlock', queryParameters: <String, String>{'mode': 'cold', 'from': from.toString()}).toString();
