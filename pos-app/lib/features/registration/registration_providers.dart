// Публичный контракт фичи registration (06 §6.14; FL-07: без data/presentation).
//
// Подключение (композиционный корень app, FL-06):
//   appOverrides.addAll(registrationOverrides)            // features/registration/data/registration_bindings.dart
// Вход в регистрацию (SCR-02 → SCR-03): после `/auth/otp/verify` → `registration_required` слой app вызывает
//   ref.read(registrationTicketProvider.notifier).start(RegistrationTicket(...))  и переходит на `/register`.
// Первый вход сотрудника по приглашению (`nextStep=set_pin`): `/register/security` с
//   `RegistrationSecurityScreen(audience: RegistrationAudience.staffFirstLogin)`.
// Маршруты экранов — app/router/routes.dart; переходы из экранов — [registrationNavigatorProvider].
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_usecases.dart';
import 'package:uuid/uuid.dart';

export 'package:optomstroy/features/registration/domain/entities/registration_entities.dart'
    show RegistrationAudience, RegistrationOutcome, RegistrationTicket;

Never _notBound(String name) => throw UnimplementedError(
  '$name: подключите registrationOverrides (features/registration/data/registration_bindings.dart)',
);

/// Сеть регистрации (реализация — data).
final registrationRepositoryProvider = Provider<RegistrationRepository>(
  (ref) => _notBound('registrationRepositoryProvider'),
);

/// Черновик регистрации (реализация — data).
final registrationDraftRepositoryProvider = Provider<RegistrationDraftRepository>(
  (ref) => _notBound('registrationDraftRepositoryProvider'),
);

/// Биометрия устройства для SCR-04 (реализация — data поверх core/biometrics).
final deviceBiometricsProvider = Provider<DeviceBiometrics>((ref) => _notBound('deviceBiometricsProvider'));

final enableBiometricLoginProvider = Provider<EnableBiometricLogin>(
  (ref) => EnableBiometricLogin(ref.watch(registrationRepositoryProvider), ref.watch(deviceBiometricsProvider)),
);

final stepUpWithPinProvider = Provider<StepUpWithPin>(
  (ref) => StepUpWithPin(ref.watch(registrationRepositoryProvider)),
);

/// Генератор `Idempotency-Key` (UUID v4); в тестах — детерминированный.
final registrationKeyGeneratorProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// `features.customerSelfService` из `GET /settings/public` (08 §4.23.1; RM-D-015, EQ-DREST-15): 4 шага с «Привязкой»
/// или 3 шага (02 AC-UI-03-002). Флаги сервера важнее флага сборки; до ответа сервера (до входа `/settings/public`
/// без Bearer → 401, EQ-DREST-16) — флаг сборки `FEATURE_CUSTOMER_SELF_SERVICE`, затем умолчание `true` (ядро §24.2).
final customerSelfServiceProvider = Provider<bool>((ref) => ref.watch(publicCustomerSelfServiceProvider));

/// Допуск к регистрации: `registration_token` — только память процесса (09 §7.1).
final registrationTicketProvider = NotifierProvider<RegistrationTicketController, RegistrationTicket?>(
  RegistrationTicketController.new,
);

final class RegistrationTicketController extends Notifier<RegistrationTicket?> {
  @override
  RegistrationTicket? build() => null;

  /// Новый `registration_required` (SCR-02 → SCR-03).
  void start(RegistrationTicket ticket) => state = ticket;

  /// После `201`, отмены, истечения, `REGISTRATION_TOKEN_INVALID`.
  void clear() => state = null;
}

/// Есть действующий черновик — SCR-01 показывает «Продолжите регистрацию…» (UI-01-017, `registration_resume`).
final registrationDraftPendingProvider = FutureProvider<bool>(
  (ref) async => (await ref.watch(registrationDraftRepositoryProvider).load()) != null,
);

/// Причина возврата на SCR-01 (02 SCR-03.6: `AuthEntryReason`).
enum RegistrationExitReason {
  registrationCancelled('registration_cancelled'),
  registrationExpired('registration_expired'),
  phoneRegistered('phone_registered'),
  loggedOut('logged_out');

  const RegistrationExitReason(this.code);

  final String code;
}

/// Переходы экранов регистрации. По умолчанию — go_router и пути карты R0 §9; app может подменить.
abstract interface class RegistrationNavigator {
  void toSecurity(BuildContext context);
  void backToForm(BuildContext context);
  void toPhone(BuildContext context, RegistrationExitReason reason);
  void toCustomerLink(BuildContext context);
  void toPendingActivation(BuildContext context);

  /// Рабочий режим роли / SCR-50: через Splash, который по сессии выбирает главный экран (06 §6.4).
  void toHome(BuildContext context);
}

final class GoRouterRegistrationNavigator implements RegistrationNavigator {
  const GoRouterRegistrationNavigator();

  @override
  void toSecurity(BuildContext context) => context.push('/register/security');

  @override
  void backToForm(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/register');
    }
  }

  @override
  void toPhone(BuildContext context, RegistrationExitReason reason) => context.go('/auth/phone?reason=${reason.code}');

  @override
  void toCustomerLink(BuildContext context) => context.go('/register/customer-link');

  @override
  void toPendingActivation(BuildContext context) => context.go('/pending-activation');

  @override
  void toHome(BuildContext context) => context.go('/splash');
}

final registrationNavigatorProvider = Provider<RegistrationNavigator>((ref) => const GoRouterRegistrationNavigator());
