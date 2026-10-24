// Проверка кода (02 SCR-02; 08 §4.1.2): код длиной ≠ 6 цифр не отправляется (SCR-02.8),
// клиент не считает попытки — `attemptsLeft` только из ответа сервера.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';

final class VerifyOtp {
  const VerifyOtp(this._repository);

  final AuthRepository _repository;

  /// Формат кода: ровно [length] цифр (ведущие нули допустимы, rule `otp_format`).
  static bool isWellFormed(String code, {int length = OtpChallenge.defaultCodeLength}) =>
      code.length == length && RegExp(r'^\d+$').hasMatch(code);

  Future<Result<VerifyOutcome>> call({required OtpChallenge challenge, required String code}) async {
    if (!isWellFormed(code, length: challenge.codeLength)) {
      return const FailureResult<VerifyOutcome>(
        ValidationFailure(
          errors: <FieldError>[FieldError(field: 'code', rule: 'otp_format')],
        ),
      );
    }
    final Result<VerifyOutcome> result = await _repository.verifyOtp(challengeId: challenge.challengeId, code: code);
    // registration_token привязан к подтверждённому номеру потока (память, 08 §2.2).
    return result.map(
      (VerifyOutcome o) =>
          o is VerifyRegistrationRequired ? VerifyRegistrationRequired(o.ticket.withPhone(challenge.phoneE164)) : o,
    );
  }
}

/// Статус доставки SMS для «SMS не пришло» (UI-02-016).
final class GetOtpDeliveryStatus {
  const GetOtpDeliveryStatus(this._repository);

  final AuthRepository _repository;

  Future<Result<OtpChallengeStatus>> call(String challengeId) => _repository.challengeStatus(challengeId);
}
