// `POST /auth/step-up` (08 §4.1.7) для резервного StepUpDialog фичи admin. PIN и код из SMS
// уходят только в теле запроса; LoggingInterceptor тела не пишет; токен не сохраняется на диск.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/admin/data/users/admin_users_dto.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

final class DioStepUpGateway implements StepUpGateway {
  DioStepUpGateway(this._dio);

  final Dio _dio;

  static const String _path = '/auth/step-up';

  @override
  Future<Result<StepUpGrant>> withPin(String operation, String pin) => ErrorMapper.guard(() async {
    final r = await _dio.post<Object?>(
      _path,
      data: {'method': StepUpMethod.pin.value, 'pin': pin, 'operation': operation},
    );
    return AdminUsersDto.stepUpGrant(r.data);
  });

  @override
  Future<Result<StepUpOtpChallenge>> requestOtp(String operation) => ErrorMapper.guard(() async {
    final r = await _dio.post<Object?>(_path, data: {'method': StepUpMethod.otp.value, 'operation': operation});
    return AdminUsersDto.otpChallenge(r.data);
  });

  @override
  Future<Result<StepUpGrant>> withOtp(String operation, {required String challengeId, required String code}) =>
      ErrorMapper.guard(() async {
        final r = await _dio.post<Object?>(
          _path,
          data: {'method': StepUpMethod.otp.value, 'operation': operation, 'challengeId': challengeId, 'code': code},
        );
        return AdminUsersDto.stepUpGrant(r.data);
      });
}
