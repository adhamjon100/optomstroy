// Разблокировка сохранённой сессии SCR-08 (08 §4.1.8; D-48; ядро §17.2, §18.2 п.5).
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';

/// Способ разблокировки (`AuthUnlockRequest.method`).
enum UnlockMethod {
  pin('pin'),
  biometric('biometric'),

  /// Ключ Windows Hello (W2; 09 BIO-039): подпись challenge вместо PIN.
  helloKey('hello_key');

  const UnlockMethod(this.value);

  final String value;
}

/// Причины `401 UNLOCK_REQUIRED` пути ключа Windows Hello (`AuthFailure.unlockReason`; 08 §4.1.8, §4.1.10;
/// 09 BIO-039; значения — `x-unlock-required-reasons` контракта).
abstract final class HelloKeyRefusal {
  /// Ключ отозван или запрещён (`AUTH_WINDOWS_HELLO_KEY`, правило `personal`), не текущий refresh — признак ключа
  /// снимается, `unlock_hello_key_unavailable`, поле PIN.
  static const String unavailable = 'hello_key_unavailable';

  /// Challenge нет, истёк, другой сессии или подпись неверна — ключ не трогается, `unlock_hello_failed`, поле PIN.
  static const String invalid = 'hello_key_invalid';
}

/// Причины `401 UNLOCK_REQUIRED` разблокировки уровнем W (`AuthFailure.unlockReason`; 08 §4.1.8; 09 BIO-031,
/// BIO-032; 02 SCR-08.4 п. 10; значения — `x-unlock-required-reasons` контракта; строки в domain, потому что domain не
/// импортирует core/network — FL-01; совпадение с `UnlockRequiredReason` закреплено тестом).
abstract final class BiometricWeakRefusal {
  /// С последнего PIN или входа по SMS на этом устройстве прошло больше `AUTH_BIO_WEAK_REAUTH_HOURS`, PIN заблокирован
  /// или не задан — секрет сохраняется, `unlock_bio_pin_due`, кнопка лица и автодиалог скрыты до успешного PIN.
  static const String pinDue = 'bio_weak_pin_due';

  /// `AUTH_BIO_ALLOW_WEAK` больше не разрешает уровень W этому пользователю, семья отозвана — секрет удаляется,
  /// `unlock_bio_weak_disabled`, поле PIN.
  static const String disabled = 'bio_weak_disabled';
}

/// Режим SCR-08 (`/auth/unlock?mode=`): полноэкранный при холодном старте или overlay.
enum UnlockMode {
  cold('cold'),
  idle('idle');

  const UnlockMode(this.value);

  final String value;

  static UnlockMode parse(String? value) => value == idle.value ? idle : cold;
}

/// Успешная разблокировка: токены сохранены data-слоем, наружу — только профиль.
final class UnlockSuccess {
  const UnlockSuccess({this.profile = SessionProfile.unknown});

  final SessionProfile profile;

  @override
  String toString() => 'UnlockSuccess()';
}
