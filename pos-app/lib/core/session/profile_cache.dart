// Кэш профиля для холодного старта (02 §0.4, SCR-00/SCR-08; 09 §9.3; D AU-06).
//
// 02 §0.4 размещает часть без ПДн (`kind`, `status`, `roles`, `security.pinSet`, `security.biometricEnabled`) в
// `app_meta`, а ФИО — в secure storage (`profile_display_name`). Локальная БД — файл пользователя
// (`pos_<user_id>.db`, 07 §11.1 п. 2, EQ-FINT-02) и открывается только после разблокировки, когда известен `sub`
// access-токена; на холодном старте (SCR-08 `cold`) её ещё нет. Поэтому обе части лежат в secure storage
// (хранилище строже `app_meta`): `profile_cache` — JSON без ПДн, `profile_display_name` — ФИО. Телефон не хранится.
// Ключи входят в `SecureKey.session` — удаляются вместе с refresh (logout, `SESSION_REVOKED`, `DEVICE_MISMATCH`);
// при входе другого пользователя перезаписываются его профилем.
//
// `userId` (02 §0.4, ред. 1.30; 15 ADR-116 п. 3; 09 BIO-034) — UUID сервера (`sub` access-токена, `Me.id`), не ПДн: на
// холодном старте по нему выбирается признак «Windows Hello перед PIN» этого пользователя (core/biometrics/
// hello_gate_users.dart). Пишет SessionController при каждом входе и разблокировке ([ProfileCacheStore.rememberUser]) и
// AuthRepositoryImpl вместе с профилем входа. Кэш прежней версии без `userId` — `userId == null`: кнопки Windows Hello
// нет до первой разблокировки PIN. Кэш только с `userId` остаётся «пустым» ([CachedProfile.isEmpty]): SCR-08 без имени
// и роли, как без кэша.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Профиль последнего входа (без телефона). `toString` — без ФИО.
@immutable
final class CachedProfile {
  const CachedProfile({
    this.userId,
    this.kind,
    this.status,
    this.roles = const <RoleCode>[],
    this.pinSet,
    this.biometricsEnabled,
    this.displayName,
  });

  /// UUID пользователя (`sub` access, `Me.id`; не ПДн); `null` — кэш прежней версии.
  final String? userId;

  final UserKind? kind;
  final UserStatus? status;
  final List<RoleCode> roles;
  final bool? pinSet;
  final bool? biometricsEnabled;

  /// ФИО (ПДн) — только для SCR-08 UI-08-003.
  final String? displayName;

  /// Профиля нет (о пользователе известен разве что [userId]).
  bool get isEmpty => kind == null && roles.isEmpty && status == null;

  /// Тот же профиль с [userId] сессии (кэш прежней версии того же пользователя).
  CachedProfile withUserId(String userId) => CachedProfile(
    userId: userId,
    kind: kind,
    status: status,
    roles: roles,
    pinSet: pinSet,
    biometricsEnabled: biometricsEnabled,
    displayName: displayName,
  );

  /// Часть без ПДн (`profile_cache`).
  String encode() => jsonEncode(<String, Object?>{
    'userId': userId,
    'kind': kind?.value,
    'status': status?.value,
    'roles': <String>[for (final RoleCode r in roles) r.value],
    'pinSet': pinSet,
    'biometricsEnabled': biometricsEnabled,
  });

  /// Разбор `profile_cache`; повреждённое значение — `null`.
  static CachedProfile? decode(String? raw, {String? displayName}) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map) return null;
      final Object? roles = j['roles'];
      final Object? userId = j['userId'];
      return CachedProfile(
        userId: userId is String && userId.trim().isNotEmpty ? userId : null,
        kind: UserKind.tryParse(j['kind'] as String?),
        status: UserStatus.tryParse(j['status'] as String?),
        roles: <RoleCode>[
          if (roles is List)
            for (final Object? r in roles)
              if (RoleCode.tryParse(r is String ? r : null) case final RoleCode role) role,
        ],
        pinSet: j['pinSet'] is bool ? j['pinSet'] as bool : null,
        biometricsEnabled: j['biometricsEnabled'] is bool ? j['biometricsEnabled'] as bool : null,
        displayName: displayName,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CachedProfile &&
      other.userId == userId &&
      other.kind == kind &&
      other.status == status &&
      listEquals(other.roles, roles) &&
      other.pinSet == pinSet &&
      other.biometricsEnabled == biometricsEnabled &&
      other.displayName == displayName;

  @override
  int get hashCode =>
      Object.hash(userId, kind, status, Object.hashAll(roles), pinSet, biometricsEnabled, displayName);

  @override
  String toString() => 'CachedProfile(${kind?.value}, ${roles.map((RoleCode r) => r.value).join(',')})';
}

/// Хранилище кэша профиля в secure storage. Сбой хранилища — как отсутствие кэша (SCR-08 без имени).
final class ProfileCacheStore {
  const ProfileCacheStore(this._storage);

  final SecureStorage _storage;

  Future<CachedProfile?> read() async {
    try {
      final String? raw = await _storage.read(SecureKey.profileCache);
      if (raw == null) return null;
      final String? name = await _storage.read(SecureKey.profileDisplayName);
      return CachedProfile.decode(raw, displayName: name);
    } on Object {
      return null;
    }
  }

  Future<void> write(CachedProfile profile) async {
    try {
      await _storage.write(SecureKey.profileCache, profile.encode());
      final String? name = profile.displayName;
      if (name == null || name.trim().isEmpty) {
        await _storage.delete(SecureKey.profileDisplayName);
      } else {
        await _storage.write(SecureKey.profileDisplayName, name);
      }
    } on Object {
      // Кэш не критичен: на холодном старте SCR-08 покажет экран без имени (строка 9 02 SCR-00).
    }
  }

  Future<void> clear() async {
    try {
      await _storage.deleteAll(const <SecureKey>[SecureKey.profileCache, SecureKey.profileDisplayName]);
    } on Object {
      // Удалять нечего / хранилище недоступно.
    }
  }

  /// `userId` сессии [userId] — в кэш (02 §0.4, ред. 1.30; 09 BIO-034). Кэш того же пользователя не меняется.
  /// [unlock] — разблокировка той же сессии: кэш прежней версии без `userId` — профиль её пользователя, дополняется
  /// `userId`. Вход (OTP, регистрация) и кэш другого `userId`: прежний профиль — чужой или неизвестный, заменяется кэшем
  /// только с `userId` (ФИО и роль другого человека SCR-08 не показывает; профиль входа по OTP AuthRepositoryImpl
  /// записывает следом).
  Future<void> rememberUser(String userId, {required bool unlock}) async {
    final CachedProfile? cached = await read();
    if (cached?.userId == userId) return;
    await write(
      cached != null && cached.userId == null && unlock ? cached.withUserId(userId) : CachedProfile(userId: userId),
    );
  }
}
