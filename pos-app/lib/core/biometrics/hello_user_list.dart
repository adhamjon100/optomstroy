// Список `userId` в одном ключе secure storage вне группы ключей сессии — основа признаков Windows Hello по
// пользователю (15 ADR-116 п. 3; 09 §8.5, BIO-034, BIO-038; 11 SEC-145, SEC-092; 07 DATA-307; 02 §0.4):
// «Windows Hello перед PIN» (W1, `auth.hello_gate_users`, hello_gate_users.dart) и «ключ Windows Hello» (W2,
// `auth.hello_key_users`, hello_key_users.dart).
//
// Значение — JSON-массив `userId` (UUID сервера, не ПДн), отсортированный, без повторов; сравнение без учёта регистра.
// Признак не содержит токенов и сессию не открывает, поэтому переживает выход, `SESSION_REVOKED` и новый вход по SMS;
// кнопку на SCR-08 видит только пользователь из списка. Сбой хранилища — как «признака нет»: исключений методы не
// бросают, а если хранилище не ответило на чтение, [HelloUserList.add] и [HelloUserList.remove] список не
// перезаписывают — признаки других пользователей устройства не теряются.
import 'dart:convert';

import 'package:flutter/foundation.dart' show protected;
import 'package:optomstroy/core/storage/secure_storage.dart';

/// Список пользователей устройства с признаком в ключе [key].
abstract base class HelloUserList {
  const HelloUserList(this.storage, this.key);

  /// Хранилище признака (и прежних значений — у наследников).
  @protected
  final SecureStorage storage;

  /// Ключ secure storage списка; не входит в `SecureKey.session` и `SecureKey.kiosk`.
  final SecureKey key;

  /// `userId` списка (без пустых и повторов). Повреждённое значение и сбой хранилища — пустой список.
  Future<Set<String>> read() async => await _readOrNull() ?? <String>{};

  /// Список или `null` — хранилище не ответило. Повреждённое значение — пустой список (перезаписывается).
  Future<Set<String>?> _readOrNull() async {
    final String? raw;
    try {
      raw = await storage.read(key);
    } on Object {
      return null;
    }
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final Object? list = jsonDecode(raw);
      if (list is! List) return <String>{};
      return <String>{
        for (final Object? id in list)
          if (normalizeUserId(id is String ? id : null) case final String userId) userId,
      };
    } on FormatException {
      return <String>{};
    }
  }

  /// Признак есть у [userId]; `null` (пользователь неизвестен — кэш профиля прежней версии) — нет.
  Future<bool> contains(String? userId) async {
    final String? id = normalizeUserId(userId);
    if (id == null) return false;
    return (await read()).contains(id);
  }

  /// Поставить признак [userId]. `false` — `userId` пустой, хранилище не ответило или запись не удалась.
  Future<bool> add(String userId) async {
    final String? id = normalizeUserId(userId);
    if (id == null) return false;
    final Set<String>? users = await _readOrNull();
    if (users == null) return false;
    if (users.contains(id)) return true;
    return _write(<String>{...users, id});
  }

  /// Снять признак только у [userId]; признаки других пользователей устройства не меняются. Список опустел — ключ
  /// удаляется. `false` — `userId` пустой, хранилище не ответило или запись не удалась; признака не было — `true`.
  Future<bool> remove(String userId) async {
    final String? id = normalizeUserId(userId);
    if (id == null) return false;
    final Set<String>? users = await _readOrNull();
    if (users == null) return false;
    if (!users.remove(id)) return true;
    return _write(users);
  }

  Future<bool> _write(Set<String> users) async {
    try {
      if (users.isEmpty) {
        await storage.delete(key);
      } else {
        await storage.write(key, jsonEncode(users.toList()..sort()));
      }
      return true;
    } on Object {
      return false;
    }
  }

  /// `userId` в виде списка: без пробелов по краям, строчными; пустой — `null`.
  static String? normalizeUserId(String? userId) {
    final String? id = userId?.trim().toLowerCase();
    return id == null || id.isEmpty ? null : id;
  }
}
