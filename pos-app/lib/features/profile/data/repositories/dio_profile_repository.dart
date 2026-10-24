// `ProfileRepository` поверх единственного Dio-клиента. Ошибки → Failure только через ErrorMapper (06 §6.8).
// ПДн ответа не логируются (LoggingInterceptor пишет только метод, путь, статус).
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/profile/data/dto/profile_dtos.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';

/// Пути API профиля (08 §4.3).
abstract final class ProfileApiPaths {
  static const String me = '/me';
  static const String profile = '/me/profile';
  static const String phoneChangeRequest = '/me/phone/change/request';
  static const String phoneChangeConfirm = '/me/phone/change/confirm';
}

final class DioProfileRepository implements ProfileRepository {
  DioProfileRepository(this._dio);

  final Dio _dio;

  @override
  Future<Result<UserProfile>> me() => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(ProfileApiPaths.me, options: apiOptions());
    return UserProfileDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<ProfileData>> update(ProfilePatch patch, {String? idempotencyKey}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.patch<Object?>(
      ProfileApiPaths.profile,
      data: ProfilePatchDto.toJson(patch),
      options: apiOptions(idempotencyKey: idempotencyKey),
    );
    return ProfileDataDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<PhoneChangeChallenge>> requestPhoneChange(String newPhoneE164, {String? stepUpToken}) =>
      ErrorMapper.guard(() async {
        final Options o = apiOptions(retry: RetryProfile.none);
        if (stepUpToken != null) {
          o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
        }
        final Response<Object?> r = await _dio.post<Object?>(
          ProfileApiPaths.phoneChangeRequest,
          data: PhoneChangeRequestDto.toJson(newPhoneE164),
          options: o,
        );
        return PhoneChangeChallengeDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<PhoneChangeResult>> confirmPhoneChange({required String challengeId, required String code}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          ProfileApiPaths.phoneChangeConfirm,
          data: PhoneChangeConfirmDto.toJson(challengeId: challengeId, code: code),
          options: apiOptions(retry: RetryProfile.none),
        );
        return PhoneChangeResultDto.fromJson(jsonObject(r.data));
      });
}
