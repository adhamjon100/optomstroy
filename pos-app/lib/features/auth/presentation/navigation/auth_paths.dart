// Адреса переходов экранов входа (карта маршрутов ядра R0 §9; 02 SCR-00/01/02/08 §6).
// Фичи не импортируют app/ (AP-01), поэтому пути — строками того же графа маршрутов,
// что объявлен в app/router/routes.dart (сверяет test/features/auth/presentation/auth_paths_test.dart).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';

abstract final class AuthPaths {
  static const String splash = '/splash';
  static const String phone = '/auth/phone';
  static const String otp = '/auth/otp';
  static const String unlock = '/auth/unlock';
  static const String register = '/register';

  /// SCR-04 — в т. ч. режим «первый вход сотрудника» (RM-D-008 читает `authSessionProvider`).
  static const String registerSecurity = '/register/security';
  static const String pendingActivation = '/pending-activation';
  static const String catalog = '/catalog';
  static const String cashier = '/cashier';
  static const String reports = '/reports';

  /// SCR-50 — главный экран клиента (каталог-заглушка до RM-E).
  static const String customerHome = '/home';

  /// Query-параметры.
  static const String reasonParam = 'reason';
  static const String returnToParam = 'returnTo';
  static const String modeParam = 'mode';
  static const String fromParam = 'from';

  /// `/auth/phone?reason=…`.
  static String phoneWith({AuthEntryReason? reason}) =>
      Uri(path: phone, queryParameters: reason == null ? null : <String, String>{reasonParam: reason.value}).toString();

  /// `/auth/unlock?mode=cold|idle&from=…`.
  static String unlockWith({UnlockMode mode = UnlockMode.cold, String? from}) => Uri(
    path: unlock,
    queryParameters: <String, String>{modeParam: mode.value, fromParam: ?safeReturnTo(from)},
  ).toString();

  /// Главный экран роли (02 SCR-02.6): seller/senior_seller/admin → SCR-10, cashier → SCR-30,
  /// owner → SCR-48, customer → SCR-50.
  static String homeFor(SessionProfile profile) => switch (profile.primaryRole) {
    RoleCode.cashier => cashier,
    RoleCode.owner => reports,
    RoleCode.customer => customerHome,
    _ => profile.isCustomer ? customerHome : catalog,
  };

  /// Куда вести после верного кода.
  static String afterVerify(VerifyOutcome outcome, {String? returnTo}) => switch (outcome) {
    VerifyAuthenticated() when outcome.mustSetPin => registerSecurity,
    VerifyAuthenticated(:final SessionProfile profile) => safeReturnTo(returnTo) ?? homeFor(profile),
    VerifyPendingActivation() => pendingActivation,
    VerifyRegistrationRequired() => register,
  };

  /// Разрешён только внутренний путь приложения вне экранов входа (без схемы/хоста).
  static String? safeReturnTo(String? value) {
    if (value == null || value.isEmpty || !value.startsWith('/') || value.startsWith('//')) {
      return null;
    }
    final String path = Uri.tryParse(value)?.path ?? '';
    const List<String> excluded = <String>[splash, '/auth', register, pendingActivation];
    if (path.isEmpty || excluded.any((String p) => path == p || path.startsWith('$p/'))) {
      return null;
    }
    return value;
  }
}
