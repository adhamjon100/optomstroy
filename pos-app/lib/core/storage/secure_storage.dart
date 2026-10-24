// Защищённое хранилище секретов (06 §6.6, 07 §11.1 п.4, 09 §8.5; ядро §18.2 п.1–3).
//
// Здесь (и только здесь): refresh-токен, `deviceId` (UUID v4), флаг биометрии,
// черновые ФИО и год рождения регистрации, кэш профиля для SCR-08 (без телефона). Access-токен и stepUpToken — только
// в памяти процесса (core/network/auth/token_store.dart), на диск не пишутся.
// Не хранятся нигде: OTP, PIN и его хэш, телефон пользователя, ключи платежей.
// Android: `allowBackup=false` (RM-C-013, 06 §6.16).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Ключи secure storage — закрытый перечень.
enum SecureKey {
  refreshToken('auth.refresh_token'),
  deviceId('device.id'),
  biometricsEnabled('auth.biometrics_enabled'),
  registrationFullName('registration.full_name'),
  registrationBirthYear('registration.birth_year'),

  /// Кэш профиля без ПДн для холодного старта (02 §0.4; D AU-06; core/session/profile_cache.dart).
  profileCache('profile_cache'),

  /// ФИО для SCR-08 (02 §0.4 `profile_display_name`).
  profileDisplayName('profile_display_name'),

  /// Отложенный выход после офлайн-выхода (02 SCR-41 UI-41-005 п. 1–5, `pending_logout`; ядро §19.4; RC-1/SS-07):
  /// `sid`, refresh-токен прежней сессии и время выхода — только для доставки `POST /auth/refresh` →
  /// `POST /auth/logout` (core/session/pending_logout.dart). Не сессия: TokenStore и вход его не читают; в [session]
  /// не входит — локальная очистка при выходе его не удаляет, удаляет только доставка (все исходы) или срок.
  pendingLogout('auth.pending_logout');

  const SecureKey(this.storageKey);

  /// Имя ключа в хранилище (`registration.*` — 07 §11.1 п.4).
  final String storageKey;

  /// Ключи черновика регистрации — удаляются вместе с `registration_draft`.
  static const List<SecureKey> registration = [registrationFullName, registrationBirthYear];

  /// Ключи сессии — удаляются при выходе / `SESSION_REVOKED` / `DEVICE_MISMATCH` (кроме `deviceId`, 07 §11.4;
  /// кэш профиля — 02 §0.4 «очистка: logout, смена пользователя, `SESSION_REVOKED`, `DEVICE_MISMATCH`»).
  static const List<SecureKey> session = [refreshToken, biometricsEnabled, profileCache, profileDisplayName];
}

/// Порт хранилища (в тестах — in-memory реализация).
abstract interface class SecureStorage {
  Future<String?> read(SecureKey key);
  Future<void> write(SecureKey key, String value);
  Future<void> delete(SecureKey key);
}

/// Реализация на `flutter_secure_storage` (Android Keystore, iOS Keychain,
/// Windows Credential Manager / DPAPI).
final class FlutterSecureStorageAdapter implements SecureStorage {
  FlutterSecureStorageAdapter([FlutterSecureStorage? storage]) : _storage = storage ?? defaultStorage;

  /// Параметры платформ: Android — `migrateOnAlgorithmChange` (06 §6.10), iOS — только
  /// это устройство после первой разблокировки (без переноса в резервные копии).
  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(SecureKey key) => _storage.read(key: key.storageKey);

  @override
  Future<void> write(SecureKey key, String value) => _storage.write(key: key.storageKey, value: value);

  @override
  Future<void> delete(SecureKey key) => _storage.delete(key: key.storageKey);
}

/// Операции над набором ключей.
extension SecureStorageOps on SecureStorage {
  Future<void> deleteAll(Iterable<SecureKey> keys) async {
    for (final key in keys) {
      await delete(key);
    }
  }

  /// Идентификатор устройства для `X-Device-Id`: UUID v4, создаётся при первом запуске
  /// и не удаляется при выходе (08 §2.2, ядро §18.2 п.3).
  Future<String> readOrCreateDeviceId({String Function()? generate}) async {
    final existing = await read(SecureKey.deviceId);
    if (existing != null && _uuidV4.hasMatch(existing)) return existing;
    final created = (generate ?? const Uuid().v4)();
    await write(SecureKey.deviceId, created);
    return created;
  }
}

final RegExp _uuidV4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
