// Пути экранов входа совпадают с типизированными маршрутами app/router/routes.dart (R0 §9):
// фича не импортирует app/ (AP-01), поэтому сверка — в тесте. Плюс — выбор главного экрана роли
// и защита `returnTo`.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/routes.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode, UserKind;
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/presentation/auth_messages.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/splash/presentation/notifiers/splash_decision.dart';

SessionProfile _p(UserKind kind, RoleCode role) => SessionProfile(kind: kind, roles: <RoleCode>[role]);

void main() {
  test('пути = маршруты routes.dart', () {
    expect(AuthPaths.splash, const SplashRoute().location);
    expect(AuthPaths.phone, const AuthPhoneRoute().location);
    expect(AuthPaths.otp, const AuthOtpRoute().location);
    expect(AuthPaths.unlock, const AuthUnlockRoute().location);
    expect(AuthPaths.register, const RegisterRoute().location);
    expect(AuthPaths.registerSecurity, const RegisterSecurityRoute().location);
    expect(AuthPaths.pendingActivation, const PendingActivationRoute().location);
    expect(AuthPaths.catalog, const CatalogRoute().location);
    expect(AuthPaths.cashier, const CashierRoute().location);
    expect(AuthPaths.reports, const ReportsRoute().location);
    expect(AuthPaths.customerHome, const HomeRoute().location);
    expect(const AuthPhoneRoute(returnTo: '/cart').location, contains('${AuthPaths.returnToParam}='));
    expect(SplashDestination.phone.location, AuthPaths.phone);
    expect(SplashDestination.unlock.location, AuthPaths.unlockWith());
    expect(SplashDestination.pendingActivation.location, AuthPaths.pendingActivation);
    expect(SplashDestination.customerHome.location, AuthPaths.customerHome);
  });

  test('главный экран роли (02 SCR-02.6)', () {
    expect(AuthPaths.homeFor(_p(UserKind.staff, RoleCode.seller)), AuthPaths.catalog);
    expect(AuthPaths.homeFor(_p(UserKind.staff, RoleCode.seniorSeller)), AuthPaths.catalog);
    expect(AuthPaths.homeFor(_p(UserKind.staff, RoleCode.admin)), AuthPaths.catalog);
    expect(AuthPaths.homeFor(_p(UserKind.staff, RoleCode.cashier)), AuthPaths.cashier);
    expect(AuthPaths.homeFor(_p(UserKind.staff, RoleCode.owner)), AuthPaths.reports);
    expect(AuthPaths.homeFor(_p(UserKind.customer, RoleCode.customer)), AuthPaths.customerHome);
  });

  test('после verify: returnTo только внутренний и не экран входа', () {
    final VerifyAuthenticated ok = VerifyAuthenticated(profile: _p(UserKind.staff, RoleCode.seller));
    expect(AuthPaths.afterVerify(ok, returnTo: '/cart'), '/cart');
    expect(AuthPaths.afterVerify(ok, returnTo: 'https://evil.example/x'), AuthPaths.catalog);
    expect(AuthPaths.afterVerify(ok, returnTo: '//evil.example'), AuthPaths.catalog);
    expect(AuthPaths.afterVerify(ok, returnTo: '/auth/otp'), AuthPaths.catalog);
    expect(AuthPaths.unlockWith(mode: UnlockMode.idle, from: '/cart'), '/auth/unlock?mode=idle&from=%2Fcart');
    expect(AuthPaths.phoneWith(reason: AuthEntryReason.pinReset), '/auth/phone?reason=pin_reset');
  });

  test('таймеры: mm:ss с округлением вверх (сервер — источник секунд)', () {
    expect(AuthMessages.mmss(const Duration(seconds: 842)), '14:02');
    expect(AuthMessages.mmss(const Duration(milliseconds: 59001)), '1:00');
    expect(AuthMessages.mmss(const Duration(seconds: 59)), '0:59');
    expect(AuthMessages.mmssPadded(const Duration(seconds: 299)), '04:59');
    expect(AuthMessages.mmss(const Duration(seconds: -3)), '0:00');
  });
}
