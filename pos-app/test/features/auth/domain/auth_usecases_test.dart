// Unit-тесты use cases входа (RM-D-007): проверка номера, запрос кода (переиспользование
// живого челленджа), проверка кода, разблокировка PIN/биометрией.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show UserKind;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/domain/usecases/request_otp.dart';
import 'package:optomstroy/features/auth/domain/usecases/unlock_session.dart';
import 'package:optomstroy/features/auth/domain/usecases/validate_phone.dart';
import 'package:optomstroy/features/auth/domain/usecases/verify_otp.dart';

import '../support/fakes.dart';

void main() {
  group('ValidatePhone (09 §3; 02 SCR-01.8)', () {
    const ValidatePhone validate = ValidatePhone();

    test('пусто → empty, 9 цифр осталось', () {
      final PhoneCheck c = validate('');
      expect(c.issue, PhoneIssue.empty);
      expect(c.remaining, 9);
      expect(c.isValid, isFalse);
    });

    test('5 цифр → short, «ещё 4»', () {
      final PhoneCheck c = validate('555 12');
      expect(c.issue, PhoneIssue.short);
      expect(c.remaining, 4);
    });

    test('маска «XXX XXX XXX» → E.164 +996XXXXXXXXX', () {
      final PhoneCheck c = validate('700 123 456');
      expect(c.issue, isNull);
      expect(c.e164, kPhoneE164);
      expect(c.remaining, 0);
    });

    test('номер, не проходящий isValid(mobile) → invalid', () {
      // 312… — городской диапазон Бишкека, не мобильный.
      final PhoneCheck c = validate('312 123 456');
      expect(c.issue, PhoneIssue.invalid);
      expect(c.e164, isNull);
    });

    test('toString без цифр номера (NFR-LOG-001)', () {
      expect(validate(kPhoneDigits).toString(), isNot(contains('123456')));
    });
  });

  group('RequestOtp', () {
    late FakeAuthRepository repo;
    late FixedClock clock;
    late RequestOtp requestOtp;

    setUp(() {
      repo = FakeAuthRepository();
      clock = FixedClock(DateTime.utc(2026, 10, 22, 9));
      requestOtp = RequestOtp(repo, clock);
    });

    test('202 → челлендж со сроками из ответа (TTL 300 с, cooldown 60 с)', () async {
      final Result<OtpRequested> r = await requestOtp(phoneE164: kPhoneE164);
      final OtpRequested ok = r.valueOrNull!;
      expect(ok.reused, isFalse);
      expect(ok.challenge.challengeId, kChallengeId);
      expect(ok.challenge.expiresAt, clock.nowUtc().add(const Duration(seconds: 300)));
      expect(ok.challenge.resendAvailableAt, clock.nowUtc().add(const Duration(seconds: 60)));
      expect(repo.requestedPhones, <String>[kPhoneE164]);
    });

    test('тот же номер с живым challengeId → без нового SMS (AC-UI-01-013)', () async {
      final OtpChallenge first = (await requestOtp(phoneE164: kPhoneE164)).valueOrNull!.challenge;
      clock.advance(const Duration(minutes: 2));
      final OtpRequested again = (await requestOtp(phoneE164: kPhoneE164, current: first)).valueOrNull!;
      expect(again.reused, isTrue);
      expect(again.challenge, same(first));
      expect(repo.requestedPhones, hasLength(1));
    });

    test('истёкший челлендж или force → новый запрос', () async {
      final OtpChallenge first = (await requestOtp(phoneE164: kPhoneE164)).valueOrNull!.challenge;
      await requestOtp(phoneE164: kPhoneE164, current: first, force: true);
      clock.advance(const Duration(minutes: 6));
      await requestOtp(phoneE164: kPhoneE164, current: first);
      expect(repo.requestedPhones, hasLength(3));
    });

    test('не E.164 → ValidationFailure без запроса', () async {
      final Result<OtpRequested> r = await requestOtp(phoneE164: '0700123456');
      expect(r.failureOrNull, isA<ValidationFailure>());
      expect(repo.requestedPhones, isEmpty);
    });

    test('ошибка сервера пробрасывается как Failure', () async {
      repo.requestResults.add(const FailureResult<OtpIssue>(otpRateLimited842));
      final Result<OtpRequested> r = await requestOtp(phoneE164: kPhoneE164);
      expect((r.failureOrNull! as AuthFailure).reason, AuthReason.otpRateLimited);
    });
  });

  group('VerifyOtp', () {
    final OtpChallenge challenge = OtpChallenge.issued(
      challengeId: kChallengeId,
      phoneE164: kPhoneE164,
      now: DateTime.utc(2026, 10, 22, 9),
      otpTtlSec: 300,
      resendAfterSec: 60,
    );

    test('код ≠ 6 цифр не отправляется (SCR-02.8)', () async {
      final FakeAuthRepository repo = FakeAuthRepository();
      final Result<VerifyOutcome> r = await VerifyOtp(repo)(challenge: challenge, code: '12a45');
      expect(r.failureOrNull, isA<ValidationFailure>());
      expect(repo.verifiedCodes, isEmpty);
      expect(VerifyOtp.isWellFormed('004512'), isTrue);
    });

    test('registration_required → билет с подтверждённым номером потока', () async {
      final FakeAuthRepository repo = FakeAuthRepository()
        ..verifyResult = Success<VerifyOutcome>(
          VerifyRegistrationRequired(
            RegistrationTicket(token: 'jwt', expiresAt: DateTime.utc(2026, 10, 22, 9, 15), phoneE164: ''),
          ),
        );
      final VerifyOutcome o = (await VerifyOtp(repo)(challenge: challenge, code: '123456')).valueOrNull!;
      expect(o, isA<VerifyRegistrationRequired>());
      expect((o as VerifyRegistrationRequired).ticket.phoneE164, kPhoneE164);
      expect(o.ticket.toString(), isNot(contains('jwt')));
    });

    test('VerifyAuthenticated.mustSetPin: приглашение или staff без PIN (D-48)', () {
      const VerifyAuthenticated invited = VerifyAuthenticated(profile: staffSeller, nextStep: AuthNextStep.setPin);
      const VerifyAuthenticated reset = VerifyAuthenticated(
        profile: SessionProfile(kind: UserKind.staff, roles: <Never>[], pinSet: false),
      );
      expect(invited.mustSetPin, isTrue);
      expect(reset.mustSetPin, isTrue);
      expect(const VerifyAuthenticated(profile: staffSeller).mustSetPin, isFalse);
    });
  });

  group('UnlockWithPin / UnlockWithBiometric (D-48, D-13)', () {
    test('PIN 4–6 цифр; иначе запрос не отправляется', () async {
      final FakeAuthRepository repo = FakeAuthRepository();
      expect((await UnlockWithPin(repo)('12')).failureOrNull, isA<ValidationFailure>());
      expect(repo.pinUnlocks, isEmpty);
      expect((await UnlockWithPin(repo)('482913')).isSuccess, isTrue);
      expect(repo.pinUnlocks.single.pin, '482913');
    });

    test('биометрия ок → unlock(biometric) и новый секрет шифруется тем же ключом', () async {
      final FakeAuthRepository repo = FakeAuthRepository();
      final FakeBiometricUnlock bio = FakeBiometricUnlock();
      final BiometricUnlockOutcome o = await UnlockWithBiometric(repo, bio)();
      expect(o, isA<BiometricUnlocked>());
      expect(repo.bioUnlocks, <String>['bio']);
      expect(bio.stored, <String>['next-bio']);
    });

    test('ключ инвалидирован → biometric_refresh удалён, запроса нет', () async {
      final FakeAuthRepository repo = FakeAuthRepository();
      final FakeBiometricUnlock bio = FakeBiometricUnlock(secret: const BiometricSecretInvalidated());
      expect(await UnlockWithBiometric(repo, bio)(), isA<BiometricUnlockInvalidated>());
      expect(bio.clears, 1);
      expect(repo.bioUnlocks, isEmpty);
    });

    test('отмена / lockout ОС → без запроса к серверу', () async {
      final FakeAuthRepository repo = FakeAuthRepository();
      expect(
        await UnlockWithBiometric(repo, FakeBiometricUnlock(secret: const BiometricSecretCancelled()))(),
        isA<BiometricUnlockCancelled>(),
      );
      expect(
        await UnlockWithBiometric(repo, FakeBiometricUnlock(secret: const BiometricSecretLockedOut()))(),
        isA<BiometricUnlockLockedOut>(),
      );
      expect(repo.bioUnlocks, isEmpty);
    });

    test('SESSION_REVOKED на биометрии → ключ удаляется', () async {
      final FakeAuthRepository repo = FakeAuthRepository()
        ..bioResult = const FailureResult<BiometricUnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));
      final FakeBiometricUnlock bio = FakeBiometricUnlock();
      expect(await UnlockWithBiometric(repo, bio)(), isA<BiometricUnlockFailed>());
      expect(bio.clears, 1);
    });
  });
}
