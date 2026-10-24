// Челлендж OTP потока входа (09 §4.4; 02 SCR-01/02 §0.4): живёт только в памяти
// процесса (AuthFlowNotifier) — номер, challengeId и сроки на диск не пишутся.
// Чистый Dart (FL-01).

/// Выданный код: ответ `202` на `POST /auth/otp/request` (08 §4.1.1) + абсолютные моменты.
///
/// Сроки пересчитываются от абсолютного времени ([expiresAt], [resendAvailableAt]),
/// а не от числа тиков таймера (02 SCR-02.11).
final class OtpChallenge {
  const OtpChallenge({
    required this.challengeId,
    required this.phoneE164,
    required this.issuedAt,
    required this.expiresAt,
    required this.resendAvailableAt,
    this.codeLength = defaultCodeLength,
    this.phoneMasked,
    this.devCode,
  });

  /// Построить по ответу сервера: TTL и cooldown — только из ответа (02 SCR-02.8).
  factory OtpChallenge.issued({
    required String challengeId,
    required String phoneE164,
    required DateTime now,
    required int otpTtlSec,
    required int resendAfterSec,
    int? codeLength,
    String? phoneMasked,
    String? devCode,
  }) => OtpChallenge(
    challengeId: challengeId,
    phoneE164: phoneE164,
    issuedAt: now,
    expiresAt: now.add(Duration(seconds: otpTtlSec)),
    resendAvailableAt: now.add(Duration(seconds: resendAfterSec)),
    codeLength: codeLength ?? defaultCodeLength,
    phoneMasked: phoneMasked,
    devCode: devCode,
  );

  /// Длина кода R1 (D-10).
  static const int defaultCodeLength = 6;

  final String challengeId;

  /// Номер потока E.164 — только память (09 §4.4).
  final String phoneE164;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final DateTime resendAvailableAt;
  final int codeLength;

  /// Маска номера с сервера (`+996 *** ** 34 56`), если пришла.
  final String? phoneMasked;

  /// Код тестового режима OTP (09 §5.8), если сервер dev/staging его вернул. Показывается только
  /// в отладочной сборке не-prod (UI-02-017, AC-UI-02-018; D_spec_questions AU-03); в логи не попадает.
  final String? devCode;

  /// Код ещё действует.
  bool isAliveAt(DateTime now) => now.isBefore(expiresAt);

  /// Повторную отправку уже можно запросить.
  bool canResendAt(DateTime now) => !now.isBefore(resendAvailableAt);

  /// Остаток срока кода (не меньше нуля).
  Duration ttlLeft(DateTime now) => _left(expiresAt, now);

  /// Остаток cooldown повторной отправки.
  Duration resendLeft(DateTime now) => _left(resendAvailableAt, now);

  /// Сервер прислал новый `resendAfterSec` (статус доставки) — сдвинуть cooldown.
  OtpChallenge withResendAvailableAt(DateTime at) => OtpChallenge(
    challengeId: challengeId,
    phoneE164: phoneE164,
    issuedAt: issuedAt,
    expiresAt: expiresAt,
    resendAvailableAt: at,
    codeLength: codeLength,
    phoneMasked: phoneMasked,
  );

  static Duration _left(DateTime at, DateTime now) {
    final Duration d = at.difference(now);
    return d.isNegative ? Duration.zero : d;
  }

  /// Без номера (NFR-LOG-001).
  @override
  String toString() => 'OtpChallenge($challengeId)';
}

/// Статус доставки SMS (`AuthOtpChallengeStatus.delivery`, 08 §4.1.9).
enum OtpDeliveryState {
  queued('queued'),
  sent('sent'),
  failed('failed');

  const OtpDeliveryState(this.value);

  final String value;

  static OtpDeliveryState? tryParse(String? value) {
    for (final OtpDeliveryState s in values) {
      if (s.value == value) {
        return s;
      }
    }
    return null;
  }
}

/// Ответ `GET /auth/otp/challenges/{challengeId}` — без ПДн (ядро §19.2).
final class OtpChallengeStatus {
  const OtpChallengeStatus({required this.challengeId, required this.delivery, this.resendAfterSec, this.expiresAt});

  final String challengeId;
  final OtpDeliveryState delivery;

  /// Остаток cooldown по данным сервера.
  final int? resendAfterSec;
  final DateTime? expiresAt;

  @override
  String toString() => 'OtpChallengeStatus($challengeId, ${delivery.value})';
}
