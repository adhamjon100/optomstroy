// Признак «ключ Windows Hello» (режим W2 — вход без PIN приложения) по `userId` вне ключей сессии (15 ADR-116 п. 3;
// 09 §8.5, BIO-038…BIO-040; 11 SEC-145; 07 DATA-307; 02 §0.4, SCR-08.4 «Windows Hello», SCR-42 UI-42-010).
//
// Признак говорит только, что [userId] включил ключ на этом устройстве: по нему SCR-08 показывает кнопку «Войти через
// Windows Hello». Сам ключ — в хранилище ключей Windows (`optomstroy.hello.v1.<userId>`), его открытый ключ — на
// сервере; вход даёт подпись challenge, проверенная сервером, а не признак. Признак переживает выход, `SESSION_REVOKED`
// и конец срока (ключ — тоже, BIO-040); снимается выключением в SCR-42 (только свой `userId`), отказом сервера
// `UNLOCK_REQUIRED hello_key_unavailable`, пропажей ключа в Windows, сверкой с `GET /me` (ключа устройства на сервере
// нет) и подключением планшета магазина (`becomeKiosk` удаляет все ключи, кроме `device.id`; 09 BIO-037).
import 'package:optomstroy/core/biometrics/hello_user_list.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Список пользователей с ключом Windows Hello на этом устройстве (`auth.hello_key_users`).
final class HelloKeyUsers extends HelloUserList {
  const HelloKeyUsers(SecureStorage storage) : super(storage, SecureKey.helloKeyUsers);
}
