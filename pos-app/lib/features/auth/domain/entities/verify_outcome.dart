// Ветвление после верного кода (08 §4.1.2; ядро v1.9 §24.2; 02 SCR-02.6).
// Токены в domain не попадают: data сохраняет их до возврата результата (И7, 02 §0.3).
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';

/// Следующий шаг после входа (`AuthAuthenticated.nextStep`).
enum AuthNextStep {
  none,

  /// Первый вход сотрудника по приглашению: SCR-04 «первый вход сотрудника» (REG-037).
  setPin,
}

/// Результат `POST /auth/otp/verify` (200).
sealed class VerifyOutcome {
  const VerifyOutcome();
}

/// `status: authenticated` — токены уже сохранены (refresh — secure storage, access — память).
final class VerifyAuthenticated extends VerifyOutcome {
  const VerifyAuthenticated({
    required this.profile,
    this.nextStep = AuthNextStep.none,
    this.viaInvitation = false,
    this.biometricRefreshOffered = false,
  });

  final SessionProfile profile;
  final AuthNextStep nextStep;

  /// `roleSource: invitation` — учётная запись создана по приглашению администратора.
  final bool viaInvitation;

  /// Предложить включить биометрию (UI-02-018) — только Android class3 / iOS.
  final bool biometricRefreshOffered;

  /// Сотрудник без PIN (после сброса или по приглашению) — сначала «Задайте PIN» (D-48).
  bool get mustSetPin => nextStep == AuthNextStep.setPin || (profile.isStaff && profile.pinSet == false);

  @override
  String toString() => 'VerifyAuthenticated($profile, nextStep: ${nextStep.name})';
}

/// `status: pending_activation` — только при `CUSTOMER_SELF_SERVICE=false` (SCR-07).
final class VerifyPendingActivation extends VerifyOutcome {
  const VerifyPendingActivation({this.profile = SessionProfile.unknown});

  final SessionProfile profile;

  @override
  String toString() => 'VerifyPendingActivation()';
}

/// `status: registration_required` — регистрация клиента (SCR-03).
final class VerifyRegistrationRequired extends VerifyOutcome {
  const VerifyRegistrationRequired(this.ticket);

  final RegistrationTicket ticket;

  @override
  String toString() => 'VerifyRegistrationRequired()';
}

/// Билет регистрации: `registrationToken` (JWT 15 мин) — только память (08 §2.2, 11 §8.1).
/// Передаётся фиче registration через `registrationTicketProvider` (auth_providers.dart).
final class RegistrationTicket {
  const RegistrationTicket({required this.token, required this.expiresAt, required this.phoneE164, this.phoneMasked});

  /// Секрет — не логируется.
  final String token;
  final DateTime expiresAt;

  /// Подтверждённый номер (память; на диске не хранится — ядро §19.3).
  final String phoneE164;
  final String? phoneMasked;

  bool isAliveAt(DateTime now) => now.isBefore(expiresAt);

  /// Номер подставляет поток входа (сервер его не возвращает).
  RegistrationTicket withPhone(String phone) =>
      RegistrationTicket(token: token, expiresAt: expiresAt, phoneE164: phone, phoneMasked: phoneMasked);

  @override
  String toString() => 'RegistrationTicket(***)';
}
