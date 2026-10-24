// Запрос кода (02 SCR-01.4 UI-01-008 п.2; 09 §4.4): тот же номер с живым challengeId —
// без нового SMS (экономия SMS, защита от обхода cooldown); иначе `POST /auth/otp/request`.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/phone_number.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';

/// Итог запроса кода.
final class OtpRequested {
  const OtpRequested(this.challenge, {required this.reused});

  final OtpChallenge challenge;

  /// `true` — использован живой челлендж из памяти, SMS не отправлялась.
  final bool reused;

  @override
  String toString() => 'OtpRequested($challenge, reused: $reused)';
}

final class RequestOtp {
  const RequestOtp(this._repository, this._clock);

  final AuthRepository _repository;
  final Clock _clock;

  /// [current] — активный челлендж потока (память). [force] — повторная отправка
  /// (ссылка «Отправить код повторно»): новый код даже при живом челлендже.
  Future<Result<OtpRequested>> call({required String phoneE164, OtpChallenge? current, bool force = false}) async {
    if (PhoneNumber.tryParseE164(phoneE164) == null) {
      return const FailureResult<OtpRequested>(
        ValidationFailure(
          errors: <FieldError>[FieldError(field: 'phone', rule: 'phone_e164')],
        ),
      );
    }
    final DateTime now = _clock.nowUtc();
    if (!force && current != null && current.phoneE164 == phoneE164 && current.isAliveAt(now)) {
      return Success<OtpRequested>(OtpRequested(current, reused: true));
    }
    final Result<OtpIssue> result = await _repository.requestOtp(phoneE164: phoneE164);
    return result.map(
      (OtpIssue issue) => OtpRequested(
        OtpChallenge.issued(
          challengeId: issue.challengeId,
          phoneE164: phoneE164,
          now: _clock.nowUtc(),
          otpTtlSec: issue.otpTtlSec,
          resendAfterSec: issue.resendAfterSec,
          codeLength: issue.codeLength,
          phoneMasked: issue.phoneMasked,
          devCode: issue.devCode,
        ),
        reused: false,
      ),
    );
  }
}
