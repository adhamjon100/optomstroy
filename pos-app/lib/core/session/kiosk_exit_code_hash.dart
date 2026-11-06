// Аварийный код выхода планшета магазина — проверка на устройстве (11 SEC-140 п. 4; 09 §8.9 п. 5, п. 7; P-002 §8.9
// п. 2; ADR-115 п. 12, п. 28, «Последствия»; 02 SCR-51 UI-51-017 п. 3; 13 TAB-2-10).
//
// Со связью код проверяет сервер (`POST /kiosk/exit`, фича kiosk). Устройство проверяет код, только когда сервер его не
// проверил: нет сети, таймаут, `426`, `401 SESSION_REVOKED`, `403 KIOSK_DISABLED`, `403 KIOSK_NETWORK_DENIED`. После
// отказа сервера (`422 KIOSK_EXIT_CODE_INVALID`, `423 KIOSK_EXIT_LOCKED`) код на устройстве не проверяется.
//
// Хэш — PBKDF2-HMAC-SHA256 (RFC 8018 §5.2) поверх пакета `crypto`: не менее 210 000 итераций, случайная соль 16 байт на
// каждое подключение, вход — код ∥ `tablet_id`. Argon2 в приложении нет, установок нет — допущение сборки (SEC-140,
// «НЕ ПОДТВЕРЖДЕНО»: слабее Argon2id сервера, принимается для 8 цифр при 5 попытках и паузе).
// Хэш, соль, счётчик неверных попыток и конец паузы — в защищённом хранилище вне ключей сессии (`SecureKey.kiosk`):
// переживают перезапуск и `SESSION_REVOKED`. Счётчик растёт ДО вычисления хэша: обрыв процесса во время проверки
// попытку не возвращает. 5 неверных подряд — пауза 15 мин. Код в открытом виде не хранится, не логируется и в
// исключения не попадает.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';

/// PBKDF2 (RFC 8018 §5.2) с PRF HMAC-SHA256: ключ длиной [length] байт.
Uint8List pbkdf2HmacSha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  int length = 32,
}) {
  if (iterations < 1 || length < 1) {
    throw ArgumentError('pbkdf2: iterations и length — не меньше 1');
  }
  final Hmac prf = Hmac(sha256, password);
  const int hashLength = 32;
  final int blocks = (length + hashLength - 1) ~/ hashLength;
  final Uint8List out = Uint8List(blocks * hashLength);
  for (var i = 1; i <= blocks; i++) {
    // U1 = PRF(P, S ∥ INT(i)); T_i = U1 ⊕ … ⊕ Uc.
    final Uint8List first = Uint8List(salt.length + 4)..setAll(0, salt);
    ByteData.sublistView(first).setUint32(salt.length, i);
    List<int> u = prf.convert(first).bytes;
    final Uint8List t = Uint8List.fromList(u);
    for (var j = 1; j < iterations; j++) {
      u = prf.convert(u).bytes;
      for (var k = 0; k < hashLength; k++) {
        t[k] ^= u[k];
      }
    }
    out.setAll((i - 1) * hashLength, t);
  }
  return Uint8List.sublistView(out, 0, length);
}

/// Вход вычисления хэша (передаётся в изолят — только простые данные).
@immutable
final class KioskExitHashInput {
  const KioskExitHashInput({required this.password, required this.salt, required this.iterations});

  final Uint8List password;
  final Uint8List salt;
  final int iterations;

  @override
  String toString() => 'KioskExitHashInput(iterations: $iterations)';
}

/// Вычисление хэша: в приложении — в отдельном изоляте (`compute`; веб — в том же потоке), в тестах — напрямую.
typedef KioskExitHashRunner = Future<Uint8List> Function(KioskExitHashInput input);

Uint8List _derive(KioskExitHashInput input) =>
    pbkdf2HmacSha256(password: input.password, salt: input.salt, iterations: input.iterations);

/// Хэш в фоне: 210 000 итераций HMAC не держат кадр интерфейса.
Future<Uint8List> computeKioskExitHash(KioskExitHashInput input) => compute(_derive, input);

/// Хэш в текущем изоляте (тесты, малое число итераций).
Future<Uint8List> deriveKioskExitHashNow(KioskExitHashInput input) async => _derive(input);

/// Итог проверки аварийного кода на устройстве.
sealed class KioskDeviceExitResult {
  const KioskDeviceExitResult();
}

/// Код верный: можно выходить из режима планшета (счётчик и пауза сброшены).
final class KioskDeviceExitAccepted extends KioskDeviceExitResult {
  const KioskDeviceExitAccepted();

  @override
  String toString() => 'KioskDeviceExitAccepted';
}

/// Код неверный; [attemptsLeft] — сколько неверных ещё до паузы.
final class KioskDeviceExitInvalid extends KioskDeviceExitResult {
  const KioskDeviceExitInvalid(this.attemptsLeft);

  final int attemptsLeft;

  @override
  String toString() => 'KioskDeviceExitInvalid($attemptsLeft)';
}

/// Пауза после 5 неверных: ввод недоступен до [until] (UTC).
final class KioskDeviceExitLocked extends KioskDeviceExitResult {
  const KioskDeviceExitLocked(this.until);

  final DateTime until;

  @override
  String toString() => 'KioskDeviceExitLocked(${until.toIso8601String()})';
}

/// Хранилище хэша аварийного кода, счётчика и паузы (ключи `SecureKey.kiosk*`).
final class KioskExitCodeStore {
  KioskExitCodeStore({
    required SecureStorage storage,
    required Clock clock,
    this.iterations = defaultIterations,
    KioskExitHashRunner? runner,
    Random? random,
  }) : _storage = storage,
       _clock = clock,
       _runner = runner ?? computeKioskExitHash,
       _random = random ?? Random.secure();

  /// Итераций PBKDF2 — не меньше 210 000 (11 SEC-140 п. 4).
  static const int defaultIterations = 210000;

  /// Соль — 16 байт на каждое подключение.
  static const int saltLength = 16;

  /// Неверных подряд до паузы (как на сервере, SEC-140 п. 3).
  static const int maxAttempts = 5;

  /// Пауза после [maxAttempts] неверных.
  static const Duration lockDuration = Duration(minutes: 15);

  /// Формат кода — ровно 8 цифр (08 §4.25.5).
  static final RegExp codeFormat = RegExp(r'^\d{8}$');

  /// Префикс записи хэша: алгоритм и число итераций хранятся рядом с хэшем (смена параметров не ломает прежние записи).
  static const String scheme = 'pbkdf2-sha256';

  final SecureStorage _storage;
  final Clock _clock;
  final KioskExitHashRunner _runner;
  final Random _random;

  /// Итераций для новых хэшей.
  final int iterations;

  /// Запомнить хэш нового кода (подключение и подключение заново, FLOW-043.S6): новая соль, счётчик и пауза сброшены.
  /// Сам код не сохраняется.
  Future<void> remember({required String code, required String tabletId}) async {
    if (!codeFormat.hasMatch(code) || tabletId.isEmpty) {
      throw ArgumentError('аварийный код: ожидалось 8 цифр и id планшета');
    }
    final Uint8List salt = Uint8List.fromList(List<int>.generate(saltLength, (_) => _random.nextInt(256)));
    final Uint8List hash = await _runner(
      KioskExitHashInput(password: _input(code, tabletId), salt: salt, iterations: iterations),
    );
    await _storage.write(SecureKey.kioskExitSalt, base64Encode(salt));
    await _storage.write(SecureKey.kioskExitHash, '$scheme\$$iterations\$${base64Encode(hash)}');
    await _storage.delete(SecureKey.kioskExitAttempts);
    await _storage.delete(SecureKey.kioskExitLockedUntil);
  }

  /// Конец действующей паузы (`null` — паузы нет).
  Future<DateTime?> lockedUntil() async {
    final DateTime? until = _parseTime(await _storage.read(SecureKey.kioskExitLockedUntil));
    if (until == null || !_clock.nowUtc().isBefore(until)) return null;
    return until;
  }

  /// Проверить [code] по хэшу на устройстве (только когда сервер код не проверил).
  Future<KioskDeviceExitResult> verify(String code) async {
    final DateTime now = _clock.nowUtc();
    final DateTime? until = _parseTime(await _storage.read(SecureKey.kioskExitLockedUntil));
    if (until != null && now.isBefore(until)) return KioskDeviceExitLocked(until);
    if (until != null) {
      // Пауза прошла — счёт заново.
      await _storage.delete(SecureKey.kioskExitLockedUntil);
      await _storage.delete(SecureKey.kioskExitAttempts);
    }
    final int attempts = (int.tryParse(await _storage.read(SecureKey.kioskExitAttempts) ?? '') ?? 0) + 1;
    // Счётчик — до вычисления: перезапуск во время проверки попытку не возвращает.
    await _storage.write(SecureKey.kioskExitAttempts, '$attempts');
    if (await _matches(code)) {
      await _storage.delete(SecureKey.kioskExitAttempts);
      await _storage.delete(SecureKey.kioskExitLockedUntil);
      return const KioskDeviceExitAccepted();
    }
    if (attempts >= maxAttempts) {
      final DateTime lockedTill = now.add(lockDuration);
      await _storage.write(SecureKey.kioskExitLockedUntil, lockedTill.toIso8601String());
      await _storage.delete(SecureKey.kioskExitAttempts);
      return KioskDeviceExitLocked(lockedTill);
    }
    return KioskDeviceExitInvalid(maxAttempts - attempts);
  }

  /// Удалить хэш, соль, счётчик и паузу (выход из режима планшета; признак удаляет `KioskMarkerStore.clear`).
  Future<void> clear() async {
    for (final SecureKey key in const <SecureKey>[
      SecureKey.kioskExitHash,
      SecureKey.kioskExitSalt,
      SecureKey.kioskExitAttempts,
      SecureKey.kioskExitLockedUntil,
    ]) {
      await _storage.delete(key);
    }
  }

  /// Нет хэша, соли или признака (подключение не завершилось) — код не принимается: обхода проверки нет.
  Future<bool> _matches(String code) async {
    if (!codeFormat.hasMatch(code)) return false;
    final String? record = await _storage.read(SecureKey.kioskExitHash);
    final String? saltText = await _storage.read(SecureKey.kioskExitSalt);
    final String? tabletId = await _storage.read(SecureKey.kioskTabletId);
    if (record == null || saltText == null || tabletId == null || tabletId.isEmpty) return false;
    final List<String> parts = record.split(r'$');
    if (parts.length != 3 || parts[0] != scheme) return false;
    final int? rounds = int.tryParse(parts[1]);
    final Uint8List expected;
    final Uint8List salt;
    try {
      expected = base64Decode(parts[2]);
      salt = base64Decode(saltText); // check-secrets: allow — соль хэша из хранилища, не секрет
    } on FormatException {
      return false;
    }
    if (rounds == null || rounds < 1 || expected.isEmpty) return false;
    final Uint8List actual = await _runner(
      KioskExitHashInput(password: _input(code, tabletId), salt: salt, iterations: rounds),
    );
    return _constantTimeEquals(actual, expected);
  }

  static Uint8List _input(String code, String tabletId) => Uint8List.fromList(utf8.encode('$code$tabletId'));

  static DateTime? _parseTime(String? raw) => raw == null ? null : DateTime.tryParse(raw)?.toUtc();

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// Хранилище аварийного кода устройства (тесты подменяют число итераций и вычисление).
final kioskExitCodeStoreProvider = Provider<KioskExitCodeStore>(
  (ref) => KioskExitCodeStore(storage: ref.watch(secureStorageProvider), clock: ref.watch(clockProvider)),
);
