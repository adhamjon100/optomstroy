// Защищённое хранилище секретов (06 §6.6, 07 §11.1 п.4, 09 §8.5; ядро §18.2 п.1–3).
//
// Здесь (и только здесь): refresh-токен, `deviceId` (UUID v4), флаг биометрии, секрет уровня W Android и признаки
// Windows Hello по `userId` — «перед PIN» (W1) и «ключ» (W2; ADR-116), черновые ФИО и год рождения регистрации, кэш профиля для SCR-08 (без телефона), признак планшета
// магазина и хэш его аварийного кода (ADR-115). Access-токен и stepUpToken — только в памяти процесса
// (core/network/auth/token_store.dart), на диск не пишутся.
// Не хранятся нигде: OTP, PIN и его хэш, телефон пользователя, ключи платежей.
// Android: `allowBackup=false` (RM-C-013, 06 §6.16).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Ключи secure storage — закрытый перечень.
enum SecureKey {
  refreshToken('auth.refresh_token'),
  deviceId('device.id'),

  /// Признак «биометрия включена на этом устройстве»: `true` — `biometric_refresh` под ключом с криптопривязкой
  /// (Android/iOS). Прежнее значение `windows_hello` (гейт Windows Hello до 15 ADR-116) переносится в [helloGateUsers]
  /// при первой разблокировке, при входе удаляется (core/biometrics/hello_gate_users.dart).
  biometricsEnabled('auth.biometrics_enabled'),

  /// Секрет уровня W Android — `biometric_refresh` семьи с `weak_reauth_due_at` (09 BIO-030, §8.5; 07 §11.1; 11 §8.1,
  /// RR-9; 15 ADR-116 п. 2): ключ Keystore `flutter_secure_storage` без привязки к аутентификации; читается и
  /// перезаписывается только композитом `AndroidBiometricAuthenticator` (после успеха диалога `local_auth`). Входит в
  /// [session]: удаляется при выходе, `SESSION_REVOKED`, `DEVICE_MISMATCH`, а также `clear()` порта биометрии и
  /// подключением планшета магазина. Секрет уровня S здесь не хранится (ключ AndroidKeyStore канала ADR-087).
  biometricRefreshWeak('auth.biometric_refresh_weak'),

  /// Признак «Windows Hello перед PIN» (режим W1; 09 BIO-034, §8.5; 11 SEC-145; 07 DATA-307; 15 ADR-116 п. 3) —
  /// JSON-массив `userId` пользователей, включивших гейт на этом устройстве (core/biometrics/hello_gate_users.dart).
  /// Вне [session]: токенов не содержит и сессию не открывает — переживает выход, `SESSION_REVOKED` и конец срока;
  /// снимается выключением в SCR-42 (только свой `userId`) и подключением планшета магазина (`becomeKiosk` удаляет все
  /// ключи, кроме `device.id`). ПДн нет (UUID сервера).
  helloGateUsers('auth.hello_gate_users'),

  /// Признак «ключ Windows Hello» (режим W2 — вход без PIN приложения; 09 BIO-038…BIO-040, §8.5; 11 SEC-145;
  /// 07 DATA-307; 15 ADR-116 п. 3) — JSON-массив `userId` пользователей, включивших ключ на этом устройстве
  /// (core/biometrics/hello_key_users.dart). Сам ключ — в хранилище ключей Windows, не здесь. Вне [session], как
  /// [helloGateUsers]: снимается выключением в SCR-42, отказом сервера `hello_key_unavailable`, пропажей ключа в
  /// Windows и подключением планшета магазина. ПДн нет.
  helloKeyUsers('auth.hello_key_users'),
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
  pendingLogout('auth.pending_logout'),

  /// Признак планшета магазина (09 §8.9 п. 7; P-002 §8.2 п. 8; ADR-115): id записи `store_tablets`. Вне [session]:
  /// переживает `401 SESSION_REVOKED` (guard G-0a); удаляют только `401 KIOSK_REVOKED` и аварийный выход
  /// (core/session/kiosk_marker.dart). ПДн нет.
  kioskTabletId('kiosk.tablet_id'),

  /// Имя планшета («Планшет у входа» — `user_profiles.full_name` технического пользователя, не ПДн).
  kioskTabletName('kiosk.tablet_name'),

  /// Технический пользователь планшета (`sub` access): БД `pos_<user>.db` с кэшем каталога открывается и без сети.
  kioskUserId('kiosk.user_id'),

  /// Склад планшета (`store_tablets.warehouse_id`; подключение SCR-54, затем `GET /me` → `tablet.warehouseId`): только
  /// для чтения кэша каталога на устройстве (наличие витрины без сети, 10 KIOSK-007); на сервер не отправляется.
  kioskWarehouseId('kiosk.warehouse_id'),

  /// Хэш аварийного кода выхода на устройстве (PBKDF2-HMAC-SHA256, 11 SEC-140 п. 4; `kiosk_exit_code_hash.dart`).
  kioskExitHash('kiosk.exit_hash'),

  /// Соль хэша аварийного кода — своя на каждое подключение (16 байт CSPRNG).
  kioskExitSalt('kiosk.exit_salt'),

  /// Неверные попытки аварийного кода подряд (проверка на устройстве; переживают перезапуск).
  kioskExitAttempts('kiosk.exit_attempts'),

  /// Конец паузы после 5 неверных кодов (UTC ISO-8601; 15 мин).
  kioskExitLockedUntil('kiosk.exit_locked_until');

  const SecureKey(this.storageKey);

  /// Имя ключа в хранилище (`registration.*` — 07 §11.1 п.4).
  final String storageKey;

  /// Ключи черновика регистрации — удаляются вместе с `registration_draft`.
  static const List<SecureKey> registration = [registrationFullName, registrationBirthYear];

  /// Ключи сессии — удаляются при выходе / `SESSION_REVOKED` / `DEVICE_MISMATCH` (кроме `deviceId`, 07 §11.4;
  /// кэш профиля — 02 §0.4 «очистка: logout, смена пользователя, `SESSION_REVOKED`, `DEVICE_MISMATCH`»).
  /// [helloGateUsers] и [helloKeyUsers] сюда не входят (11 SEC-092, SEC-145).
  static const List<SecureKey> session = [
    refreshToken,
    biometricsEnabled,
    biometricRefreshWeak,
    profileCache,
    profileDisplayName,
  ];

  /// Ключи режима «Планшет магазина» — признак, хэш, соль, счётчик и пауза аварийного кода (09 §8.9 п. 7). В [session]
  /// не входят: `SESSION_REVOKED` их не удаляет; удаляются вместе только при `KIOSK_REVOKED` и аварийном выходе.
  static const List<SecureKey> kiosk = [
    kioskTabletId,
    kioskTabletName,
    kioskUserId,
    kioskWarehouseId,
    kioskExitHash,
    kioskExitSalt,
    kioskExitAttempts,
    kioskExitLockedUntil,
  ];
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
