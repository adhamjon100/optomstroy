// Признак «Windows Hello перед PIN» (режим W1) по `userId` вне ключей сессии (15 ADR-116 п. 3; 09 BIO-034, §8.5;
// 11 SEC-145, SEC-092; 07 DATA-307; 02 §0.4).
//
// Windows Hello в режиме W1 — только UX-гейт перед обязательным PIN приложения (09 BIO-005, AC-AUTH-067): признак не
// содержит токенов и сессию не открывает, поэтому хранится вне `SecureKey.session` — переживает выход,
// `SESSION_REVOKED`, конец срока и новый вход по SMS. Признак — список `userId` (`auth.hello_gate_users`): кнопку
// «Windows Hello» на SCR-08 видит только пользователь из списка (`userId` сессии, на холодном старте — из кэша профиля,
// core/session/profile_cache.dart). Снимается выключением в SCR-42 (только свой `userId`), включением ключа Windows
// Hello тем же пользователем (W2, hello_key_users.dart; 02 SCR-42 UI-42-010) и подключением планшета магазина
// (`SessionController.becomeKiosk` удаляет все ключи, кроме `device.id`; 09 BIO-037). Чтение и запись списка —
// hello_user_list.dart.
//
// До ADR-116 признак был значением `windows_hello` ключа сессии `auth.biometrics_enabled` (общий для устройства, после
// входа другого пользователя оставался ему). Он переносится на `userId` при первой разблокировке той же сессии
// ([HelloGateUsers.adoptLegacy]); при входе по SMS или регистрации владелец прежнего значения неизвестен — оно
// удаляется ([HelloGateUsers.dropLegacy]), гейт включается в SCR-42 заново.
//
// Сбой хранилища — как «признака нет» (только PIN): исключений методы не бросают.
import 'package:optomstroy/core/biometrics/hello_user_list.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Список пользователей с гейтом Windows Hello на этом устройстве (`auth.hello_gate_users`).
final class HelloGateUsers extends HelloUserList {
  const HelloGateUsers(SecureStorage storage) : super(storage, SecureKey.helloGateUsers);

  /// Прежнее значение `auth.biometrics_enabled` для гейта Windows Hello (до 15 ADR-116; RB-09, RM-D-008).
  static const String legacyFlag = 'windows_hello';

  /// Первая разблокировка сессии [userId] после обновления: прежнее значение `windows_hello` ключа сессии — признак
  /// этой сессии; переносится в список, прежний ключ удаляется. `true` — признак перенесён.
  Future<bool> adoptLegacy(String userId) async {
    if (!await _hasLegacy()) return false;
    if (!await add(userId)) return false;
    await _deleteLegacy();
    return true;
  }

  /// Вход по SMS или регистрация: прежнее значение `windows_hello` принадлежит неизвестному пользователю — удаляется
  /// (чужой гейт новому пользователю не достаётся, BIO-034). Значение `true` (криптопривязка) не трогается.
  Future<void> dropLegacy() async {
    if (await _hasLegacy()) await _deleteLegacy();
  }

  Future<bool> _hasLegacy() async {
    try {
      return await storage.read(SecureKey.biometricsEnabled) == legacyFlag;
    } on Object {
      return false;
    }
  }

  Future<void> _deleteLegacy() async {
    try {
      await storage.delete(SecureKey.biometricsEnabled);
    } on Object {
      // Хранилище недоступно — значение не читается как гейт ни адаптером, ни SCR-42.
    }
  }
}
