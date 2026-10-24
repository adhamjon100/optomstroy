// Хранение токенов сессии (06 §6.6; ядро §18.2 п.2): access-токен и stepUpToken —
// только в памяти процесса; refresh-токен — только в secure storage.
import 'package:optomstroy/core/storage/secure_storage.dart';

final class TokenStore {
  TokenStore(this._storage);

  final SecureStorage _storage;
  String? _accessToken;

  /// Access JWT (в памяти; после перезапуска — `null`, получается через refresh).
  String? get accessToken => _accessToken;

  Future<String?> readRefreshToken() => _storage.read(SecureKey.refreshToken);

  /// Сохранить новую пару после входа / refresh / unlock.
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    _accessToken = accessToken;
    await _storage.write(SecureKey.refreshToken, refreshToken);
  }

  /// Сбросить только access (например, при блокировке по простою).
  void clearAccessToken() => _accessToken = null;

  /// Выход / `SESSION_REVOKED`: токены удаляются, `deviceId` сохраняется (07 §11.4).
  Future<void> clearSession() async {
    _accessToken = null;
    await _storage.deleteAll(SecureKey.session);
  }
}
