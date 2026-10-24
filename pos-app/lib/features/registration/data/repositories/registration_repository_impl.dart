// Реализация [RegistrationRepository] (08 §4.2, §4.3; 09 §7.3). Токены `201` передаются в сессию
// ([establishSession] → SessionController.establish, RM-D-009): access — только память, refresh — secure storage
// (ядро §18.2 п.2). Без колбэка (тесты) — напрямую в TokenStore. PIN нигде не сохраняется.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/registration/data/datasources/registration_api.dart';
import 'package:optomstroy/features/registration/data/device_descriptor.dart';
import 'package:optomstroy/features/registration/data/models/registration_dtos.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';

final class RegistrationRepositoryImpl implements RegistrationRepository {
  RegistrationRepositoryImpl({
    required RegistrationApi api,
    required TokenStore tokens,
    required DeviceDescriptorSource device,
    required Future<String?> Function() deviceBiometricClass,
    Future<void> Function(String accessToken, String refreshToken)? establishSession,
    Future<void> Function()? sessionLogout,
    Future<void> Function()? onSessionCleared,
  }) : _api = api,
       _tokens = tokens,
       _device = device,
       _deviceBiometricClass = deviceBiometricClass,
       _establishSession = establishSession,
       _sessionLogout = sessionLogout,
       _onSessionCleared = onSessionCleared;

  final RegistrationApi _api;
  final TokenStore _tokens;
  final DeviceDescriptorSource _device;
  final Future<String?> Function() _deviceBiometricClass;
  final Future<void> Function(String accessToken, String refreshToken)? _establishSession;
  final Future<void> Function()? _sessionLogout;
  final Future<void> Function()? _onSessionCleared;

  @override
  Future<Result<RegistrationOutcome>> complete(RegistrationRequest request, {required String idempotencyKey}) async {
    final device = await _device.describe(biometricClass: await _deviceBiometricClass());
    return ErrorMapper.guard(() async {
      final json = await _api.complete(
        RegistrationDtos.completeRequest(request, device),
        idempotencyKey: idempotencyKey,
      );
      final tokens = RegistrationDtos.tokens(json);
      if (tokens == null) throw const FormatException('registration/complete: нет токенов');
      final establish = _establishSession;
      if (establish != null) {
        await establish(tokens.access, tokens.refresh);
      } else {
        await _tokens.saveTokens(accessToken: tokens.access, refreshToken: tokens.refresh);
      }
      return RegistrationDtos.outcome(json);
    });
  }

  @override
  Future<Result<CustomerMatch>> customerMatch() =>
      ErrorMapper.guard(() async => RegistrationDtos.customerMatch(await _api.customerMatch()));

  @override
  Future<Result<CustomerMatch>> confirmCustomerMatch(String linkId) => _resolve(linkId, confirm: true);

  @override
  Future<Result<CustomerMatch>> rejectCustomerMatch(String linkId) => _resolve(linkId, confirm: false);

  Future<Result<CustomerMatch>> _resolve(String linkId, {required bool confirm}) => ErrorMapper.guard(
    () async => RegistrationDtos.customerMatch(await _api.resolveCustomerMatch(linkId, confirm: confirm)),
  );

  @override
  Future<Result<String?>> enableBiometrics({required String? biometricClass, String? stepUpToken}) =>
      ErrorMapper.guard(() async {
        final json = await _api.biometrics(RegistrationDtos.enableBiometrics(biometricClass), stepUpToken: stepUpToken);
        return RegistrationDtos.biometricRefreshToken(json);
      });

  @override
  Future<Result<void>> disableBiometrics({String? stepUpToken}) => ErrorMapper.guard(() async {
    await _api.biometrics(const <String, Object?>{'enabled': false}, stepUpToken: stepUpToken);
  });

  @override
  Future<Result<String>> stepUpWithPin({required String pin, required String operation}) => ErrorMapper.guard(() async {
    final token = RegistrationDtos.stepUpToken(await _api.stepUp(RegistrationDtos.stepUpPin(pin, operation)));
    if (token == null) throw const FormatException('auth/step-up: нет stepUpToken');
    return token;
  });

  @override
  Future<Result<void>> setPin(String newPin, {String? stepUpToken}) =>
      ErrorMapper.guard(() => _api.setPin(newPin, stepUpToken: stepUpToken));

  @override
  Future<Result<void>> acknowledgePersonalData() =>
      ErrorMapper.guard(() => _api.grantConsent(kind: 'personal_data', version: ConsentVersions.personalData));

  @override
  Future<Result<AccountSnapshot>> fetchAccount() =>
      ErrorMapper.guard(() async => RegistrationDtos.account(await _api.me()));

  @override
  Future<void> logout() async {
    final sessionLogout = _sessionLogout;
    if (sessionLogout != null) {
      await sessionLogout();
      await _onSessionCleared?.call();
      return;
    }
    try {
      await _api.logout();
    } on DioException {
      // Офлайн или ошибка сервера: выход на устройстве выполняется всё равно (09 §8.6, 02 UI-07-008).
    }
    await _tokens.clearSession();
    await _onSessionCleared?.call();
  }
}
