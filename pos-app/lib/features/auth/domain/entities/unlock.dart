// Разблокировка сохранённой сессии SCR-08 (08 §4.1.8; D-48; ядро §17.2, §18.2 п.5).
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';

/// Способ разблокировки (`AuthUnlockRequest.method`).
enum UnlockMethod {
  pin('pin'),
  biometric('biometric');

  const UnlockMethod(this.value);

  final String value;
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
