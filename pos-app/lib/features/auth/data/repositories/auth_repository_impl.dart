// Реализация AuthRepository (08 §4.1; ядро §18.2 п.2–5).
//
// Токены: access — только память (TokenStore), refresh — secure storage; сохраняются
// **до** возврата успеха наружу (02 §0.3 И7: прерывание анимации не отменяет вход).
// `registration_token` — только память (RegistrationTicket), на диск не пишется.
// Телефон, код, PIN и токены не логируются и не попадают в toString.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/me.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/auth/data/datasources/auth_remote_data_source.dart';
import 'package:optomstroy/features/auth/data/device_info_source.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';

/// Сохранение пары токенов после входа/разблокировки. По умолчанию — [TokenStore.saveTokens];
/// композиционный корень передаёт `SessionController.establish` (core/session, RM-D-009),
/// чтобы `sessionStatusProvider` перешёл в `authenticated` и запустился idle-таймер.
typedef SessionTokensSink =
    Future<void> Function({
      required String accessToken,
      required String refreshToken,
    }); // check-secrets: allow (имя поля / тестовое значение)

final class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({
    required AuthRemoteDataSource remote,
    required TokenStore tokens,
    required DeviceInfoSource device,
    required Clock clock,
    String Function()? locale,
    SessionTokensSink? onSession,
    ProfileCacheStore? profileCache,
  }) : _remote = remote,
       _profileCache = profileCache,
       _tokens = tokens,
       _device = device,
       _clock = clock,
       _locale = locale ?? _ru,
       _onSession = onSession ?? tokens.saveTokens;

  static String _ru() => 'ru';

  final AuthRemoteDataSource _remote;
  final TokenStore _tokens;
  final DeviceInfoSource _device;
  final Clock _clock;
  final String Function() _locale;
  final SessionTokensSink _onSession;

  /// Кэш профиля для холодного старта (02 §0.4, D AU-06); `null` — только память процесса.
  final ProfileCacheStore? _profileCache;

  /// Профиль последнего входа (память процесса); после перезапуска — из [_profileCache].
  SessionProfile? _profile;

  @override
  Future<Result<OtpIssue>> requestOtp({required String phoneE164}) => ErrorMapper.guard(() async {
    final OtpRequestResponseDto r = await _remote.requestOtp(OtpRequestRequestDto(phone: phoneE164, locale: _locale()));
    return OtpIssue(
      challengeId: r.challengeId,
      resendAfterSec: r.resendAfterSec,
      otpTtlSec: r.otpTtlSec,
      codeLength: r.codeLength,
      phoneMasked: r.phoneMasked,
      devCode: r.devCode,
    );
  });

  @override
  Future<Result<OtpChallengeStatus>> challengeStatus(String challengeId) => ErrorMapper.guard(() async {
    final OtpChallengeStatusDto r = await _remote.challengeStatus(challengeId);
    final OtpDeliveryState? delivery = OtpDeliveryState.tryParse(r.delivery);
    if (delivery == null) {
      throw const DtoFormatException('delivery');
    }
    return OtpChallengeStatus(
      challengeId: r.challengeId,
      delivery: delivery,
      resendAfterSec: r.resendAfterSec,
      expiresAt: r.expiresAt,
    );
  });

  @override
  Future<Result<VerifyOutcome>> verifyOtp({required String challengeId, required String code}) =>
      ErrorMapper.guard(() async {
        final AuthDeviceInfoDto device = await _device.read();
        final OtpVerifyResponseDto r = await _remote.verifyOtp(
          OtpVerifyRequestDto(challengeId: challengeId, code: code, device: device),
        );
        switch (r) {
          case AuthAuthenticatedDto():
            await _onSession(accessToken: r.accessToken, refreshToken: r.refreshToken);
            final SessionProfile profile = profileOf(r.user);
            await _remember(profile);
            return VerifyAuthenticated(
              profile: profile,
              nextStep: r.nextStep == 'set_pin' ? AuthNextStep.setPin : AuthNextStep.none,
              viaInvitation: r.roleSource == 'invitation',
              biometricRefreshOffered: r.biometricRefreshOffered ?? false,
            );
          case AuthPendingActivationDto():
            await _onSession(accessToken: r.accessToken, refreshToken: r.refreshToken);
            final SessionProfile profile = profileOf(r.user);
            await _remember(profile);
            return VerifyPendingActivation(profile: profile);
          case AuthRegistrationRequiredDto():
            final int ttl = r.registrationExpiresIn ?? AuthRegistrationRequiredDto.defaultExpiresIn;
            return VerifyRegistrationRequired(
              RegistrationTicket(
                token: r.registrationToken,
                expiresAt: _clock.nowUtc().add(Duration(seconds: ttl)),
                // Номер подставляет VerifyOtp (сервер его не возвращает).
                phoneE164: '',
                phoneMasked: r.phoneMasked,
              ),
            );
        }
      });

  @override
  Future<Result<UnlockSuccess>> unlockWithPin({required String pin, bool biometricInvalidated = false}) async {
    final String? refresh = await _readRefresh();
    if (refresh == null) {
      return const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));
    }
    final Result<UnlockSuccess> result = await ErrorMapper.guard(() async {
      final AuthUnlockResponseDto r = await _remote.unlock(
        AuthUnlockRequestDto(
          method: UnlockMethod.pin.value,
          refreshToken: refresh,
          pin: pin,
          biometricInvalidated: biometricInvalidated ? true : null,
        ),
      );
      await _onSession(accessToken: r.accessToken, refreshToken: r.refreshToken);
      return UnlockSuccess(profile: await cachedProfile());
    });
    await _onFailure(result.failureOrNull);
    return result;
  }

  @override
  Future<Result<BiometricUnlockSuccess>> unlockWithBiometric({required String biometricRefresh}) async {
    final Result<BiometricUnlockSuccess> result = await ErrorMapper.guard(() async {
      final AuthUnlockResponseDto r = await _remote.unlock(
        AuthUnlockRequestDto(method: UnlockMethod.biometric.value, refreshToken: biometricRefresh),
      );
      // Новый biometric refresh шифруется ключом биометрии (порт), в открытом secure storage
      // не хранится; обычный refresh сессии остаётся прежним (см. D_spec_questions, RM-D-007).
      final String? standard = await _readRefresh();
      if (standard == null) {
        throw const DtoFormatException('refreshToken');
      }
      await _onSession(accessToken: r.accessToken, refreshToken: standard);
      return BiometricUnlockSuccess(
        result: UnlockSuccess(profile: await cachedProfile()),
        nextSecret: r.refreshToken,
      );
    });
    await _onFailure(result.failureOrNull);
    return result;
  }

  @override
  Future<bool> hasStoredSession() async => await _readRefresh() != null;

  @override
  Future<SessionProfile> cachedProfile() async {
    final SessionProfile? memory = _profile;
    if (memory != null) return memory;
    final CachedProfile? cached = await _profileCache?.read();
    if (cached == null || cached.isEmpty) return SessionProfile.unknown;
    return _profile = SessionProfile(
      kind: cached.kind,
      roles: cached.roles,
      status: cached.status,
      pinSet: cached.pinSet,
      biometricsEnabled: cached.biometricsEnabled,
      displayName: cached.displayName,
    );
  }

  @override
  Future<void> clearLocalSession() async {
    _profile = null;
    // `profile_cache`/`profile_display_name` входят в `SecureKey.session` — удаляются вместе с refresh.
    await _tokens.clearSession();
  }

  /// Профиль входа → память и кэш холодного старта. `pinSet=false` не кэшируется (`null`): PIN могут задать после
  /// входа (первый вход сотрудника, SCR-42), а устаревшее `false` скрыло бы клавиатуру PIN на SCR-08.
  Future<void> _remember(SessionProfile profile) async {
    _profile = profile;
    await _profileCache?.write(
      CachedProfile(
        kind: profile.kind,
        status: profile.status,
        roles: profile.roles,
        pinSet: profile.pinSet == true ? true : null,
        biometricsEnabled: profile.biometricsEnabled,
        displayName: profile.displayName,
      ),
    );
  }

  /// Отзыв сессии сервером: токены удаляются, `deviceId` сохраняется (07 §11.4).
  Future<void> _onFailure(Failure? failure) async {
    if (failure is AuthFailure &&
        (failure.reason == AuthReason.sessionRevoked || failure.reason == AuthReason.deviceMismatch)) {
      await clearLocalSession();
    }
  }

  Future<String?> _readRefresh() async {
    try {
      return await _tokens.readRefreshToken();
    } on Object {
      // Сбой secure storage (например, после восстановления из бэкапа) — как отсутствие сессии.
      return null;
    }
  }

  /// `Me` → профиль без телефона.
  static SessionProfile profileOf(Me? me) {
    if (me == null) {
      return SessionProfile.unknown;
    }
    return SessionProfile(
      kind: me.userKind,
      roles: me.roleCodes,
      status: me.userStatus,
      pinSet: me.security?.pinSet,
      biometricsEnabled: me.security?.biometricsEnabled,
      displayName: me.profile?.fullName,
    );
  }
}
