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
/// - на `/splash` после восстановления решение принимает SplashScreen (02 SCR-00.6: staff → SCR-08 `cold`,
///   customer без PIN → SCR-50, гость → SCR-01; ANIM-001 не обрывается — D_spec_questions AU-05);
/// - нет сессии и маршрут защищён → `/auth/phone?returnTo=<адрес>`; после явного выхода ([endReason]
///   `logout` / `logoutAll`) — без `returnTo`: стек очищен, следующий вход не продолжает путь прежнего
///   пользователя (09 §8.6, 02 SCR-42.6; EQ-DREST-17);
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
}) {
  final path = uri.path;
  final splash = const SplashRoute().location;
  if (status == SessionStatus.unknown) {
    return path == splash ? null : splash;
  }
  if (path == splash) {
    return null;
  }
  final authenticated = status == SessionStatus.authenticated;
  if (!authenticated && !isPublicPath(path)) {
    final explicitLogout = endReason == SessionEndReason.logout || endReason == SessionEndReason.logoutAll;
    return AuthPhoneRoute(returnTo: explicitLogout ? null : uri.toString()).location;
  }
  if (authenticated && lock == SessionLockReason.coldStart && !isPublicPath(path)) {
    return coldUnlockLocation(uri);
  }
  return null;
}

/// Адрес SCR-08 `cold` с возвратом на [from] (G-5: `/auth/unlock?mode=cold&from=<адрес>`).
String coldUnlockLocation(Uri from) =>
    Uri(path: '/auth/unlock', queryParameters: <String, String>{'mode': 'cold', 'from': from.toString()}).toString();
