// Публичный контракт фичи auth (06 §6.14; FL-03, FL-07): провайдеры-интерфейсы и use cases.
//
// Реализации подключает композиционный корень: `app/di/overrides.dart` добавляет
// `...authBindings` (features/auth/data/auth_bindings.dart) — до этого действует
// [UnboundAuthRepository] (вызовы API возвращают ошибку, сохранённой сессии нет) и
// [NoBiometricUnlock] (только PIN). Импорт этого файла разрешён фичам registration,
// profile, settings (DAG 06 §6.1).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/domain/usecases/request_otp.dart';
import 'package:optomstroy/features/auth/domain/usecases/unlock_session.dart';
import 'package:optomstroy/features/auth/domain/usecases/validate_phone.dart';
import 'package:optomstroy/features/auth/domain/usecases/verify_otp.dart';

// Порт защиты экрана ввода OTP/PIN — core/session (общий для всех экранов ввода PIN/OTP, E-security-4).
export 'package:optomstroy/core/session/secure_screen.dart' show NoSecureScreen, SecureScreen, secureScreenProvider;

/// Репозиторий входа; реализация — `authBindings`.
final authRepositoryProvider = Provider<AuthRepository>((ref) => const UnboundAuthRepository());

/// Биометрия SCR-08 (порт к `BiometricAuthenticator` core/hardware); по умолчанию — только PIN.
final biometricUnlockProvider = Provider<BiometricUnlock>((ref) => const NoBiometricUnlock());

/// Сигнал «нет сетевого интерфейса» для экранов входа (OfflineBanner SCR-01/02/08).
///
/// По умолчанию `false`: экраны узнают об офлайне по исходу запросов (`NetworkFailure`).
/// Композиционный корень может подставить сигнал `onlineStatusProvider` (connectivity_plus).
final authOfflineSignalProvider = Provider<bool>((ref) => false);

/// Подсказка `devCode` на SCR-02 (UI-02-017; 09 §4.6; AU-03): только сборка `ENV=dev` (в т. ч. `flutter test`) и не
/// release, и только если сервер вернул поле (`OtpIssue.devCode`, вне ключей контракта — EQ-DREST-12). `staging`
/// и `prod` подсказку не показывают; в release-сборке её нет даже при наличии поля в ответе (AC-UI-02-018).
final authDevCodeHintProvider = Provider<bool>(
  (ref) => !kReleaseMode && ref.watch(appConfigProvider).environment == AppEnvironment.dev,
);

/// Неотправленные изменения прежнего сотрудника на этом устройстве для предупреждения SCR-01 (04 FLOW-002.A3,
/// FLOW-009.E1; 07 §11.4 «при входе другого сотрудника — то же предупреждение на экране входа»; FIX-EF-10).
/// `null` — предупреждать не о чем. Реализация (локальная БД прежнего пользователя через core/session) —
/// `authBindings`; без привязок — `null`.
final authPendingChangesNoticeProvider = FutureProvider.autoDispose<PendingChangesNotice?>((ref) async => null);

/// Предупреждение SCR-01 о неотправленном прежнего сотрудника. ФИО — ПДн: только память, без `toString`.
final class PendingChangesNotice {
  const PendingChangesNotice({this.ownerName});

  /// ФИО владельца изменений (кэш профиля); `null` — неизвестно (текст без имени).
  final String? ownerName;

  @override
  String toString() => 'PendingChangesNotice(***)';
}

final validatePhoneProvider = Provider<ValidatePhone>((ref) => const ValidatePhone());

final requestOtpProvider = Provider<RequestOtp>(
  (ref) => RequestOtp(ref.watch(authRepositoryProvider), ref.watch(clockProvider)),
);

final verifyOtpProvider = Provider<VerifyOtp>((ref) => VerifyOtp(ref.watch(authRepositoryProvider)));

final otpDeliveryStatusProvider = Provider<GetOtpDeliveryStatus>(
  (ref) => GetOtpDeliveryStatus(ref.watch(authRepositoryProvider)),
);

final unlockWithPinProvider = Provider<UnlockWithPin>((ref) => UnlockWithPin(ref.watch(authRepositoryProvider)));

final unlockWithBiometricProvider = Provider<UnlockWithBiometric>(
  (ref) => UnlockWithBiometric(ref.watch(authRepositoryProvider), ref.watch(biometricUnlockProvider)),
);

/// Состояние сессии, известное фиче auth (мост к `core/session` — RM-D-009).
enum AuthSessionStatus {
  /// Нет сессии (или вышли).
  signedOut,

  /// Вход выполнен, рабочие экраны доступны.
  signedIn,

  /// Вход выполнен, но нужен PIN (сотрудник по приглашению / после сброса, D-48).
  pinSetupRequired,

  /// `pending_activation` (SCR-07).
  pendingActivation,
}

/// Снимок сессии.
final class AuthSessionState {
  const AuthSessionState(this.status, [this.profile = SessionProfile.unknown]);

  static const AuthSessionState signedOut = AuthSessionState(AuthSessionStatus.signedOut);

  final AuthSessionStatus status;
  final SessionProfile profile;

  @override
  String toString() => 'AuthSessionState(${status.name}, $profile)';
}

/// Последний известный исход входа/разблокировки. Читает core/session (RM-D-009) и роутер,
/// чтобы перевести `sessionStatusProvider` в `authenticated` после SCR-02/SCR-08.
final authSessionProvider = NotifierProvider<AuthSessionNotifier, AuthSessionState>(AuthSessionNotifier.new);

final class AuthSessionNotifier extends Notifier<AuthSessionState> {
  @override
  AuthSessionState build() => AuthSessionState.signedOut;

  void signedIn(SessionProfile profile) => state = AuthSessionState(AuthSessionStatus.signedIn, profile);

  void pinSetupRequired(SessionProfile profile) =>
      state = AuthSessionState(AuthSessionStatus.pinSetupRequired, profile);

  void pendingActivation(SessionProfile profile) =>
      state = AuthSessionState(AuthSessionStatus.pendingActivation, profile);

  void signedOut() => state = AuthSessionState.signedOut;
}

/// Билет регистрации после `registration_required` (память, TTL 15 мин) — читает фича
/// registration (SCR-03/04); после `201` или выхода — [RegistrationTicketNotifier.clear].
final registrationTicketProvider = NotifierProvider<RegistrationTicketNotifier, RegistrationTicket?>(
  RegistrationTicketNotifier.new,
);

final class RegistrationTicketNotifier extends Notifier<RegistrationTicket?> {
  @override
  RegistrationTicket? build() => null;

  void set(RegistrationTicket ticket) => state = ticket;

  void clear() => state = null;
}

/// Репозиторий до подключения `authBindings`: API недоступен, сохранённой сессии нет.
final class UnboundAuthRepository implements AuthRepository {
  const UnboundAuthRepository();

  static const Failure _unbound = UnknownFailure(cause: 'auth_repository_unbound');

  @override
  Future<Result<OtpIssue>> requestOtp({required String phoneE164}) async => const FailureResult<OtpIssue>(_unbound);

  @override
  Future<Result<OtpChallengeStatus>> challengeStatus(String challengeId) async =>
      const FailureResult<OtpChallengeStatus>(_unbound);

  @override
  Future<Result<VerifyOutcome>> verifyOtp({required String challengeId, required String code}) async =>
      const FailureResult<VerifyOutcome>(_unbound);

  @override
  Future<Result<UnlockSuccess>> unlockWithPin({required String pin, bool biometricInvalidated = false}) async =>
      const FailureResult<UnlockSuccess>(_unbound);

  @override
  Future<Result<BiometricUnlockSuccess>> unlockWithBiometric({required String biometricRefresh}) async =>
      const FailureResult<BiometricUnlockSuccess>(_unbound);

  @override
  Future<bool> hasStoredSession() async => false;

  @override
  Future<SessionProfile> cachedProfile() async => SessionProfile.unknown;

  @override
  Future<void> clearLocalSession() async {}
}
