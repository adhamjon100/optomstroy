// Кэш stepUpToken (08 §2.12; ядро §18.2 п.6, §17.2): токен многоразовый 15 мин для операций
// своей области `scope`; хранится только в памяти процесса (06 §6.6), очищается при выходе,
// завершении и блокировке сессии. Значение токена в toString/логи не попадает.
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/utils/clock.dart';

/// Выданный `POST /auth/step-up` токен (`AuthStepUpToken`).
@immutable
final class StepUpGrant {
  const StepUpGrant({
    required this.token,
    required this.operation,
    required this.expiresAt,
    required this.method,
    this.scope = const <String>[],
  });

  /// Разбор ответа `200 POST /auth/step-up`; [operation] — запрошенная операция.
  factory StepUpGrant.fromJson(Map<String, dynamic> json, {required String operation}) {
    final scope = json['scope'];
    return StepUpGrant(
      token: json['stepUpToken'] as String,
      operation: operation,
      expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
      method: json['method'] as String,
      scope: scope is List ? scope.whereType<String>().toList(growable: false) : const <String>[],
    );
  }

  final String token;

  /// Операция, для которой токен получен (`stepUp.operation`).
  final String operation;
  final DateTime expiresAt;

  /// `pin` | `otp`.
  final String method;

  /// Коды permissions области (11 §4.3), выведенные сервером из `operation`.
  final List<String> scope;

  /// Токен покрывает [op]: та же операция или код в `scope`.
  bool covers(String op) => op == operation || scope.contains(op);

  @override
  String toString() => 'StepUpGrant($operation, $method, until: $expiresAt)';
}

final class StepUpTokenCache {
  StepUpTokenCache({required Clock clock, Duration skew = const Duration(seconds: 15)}) : _clock = clock, _skew = skew;

  final Clock _clock;
  final Duration _skew;
  final List<StepUpGrant> _grants = <StepUpGrant>[];

  /// Сохранить токен (заменяет прежний той же операции).
  void put(StepUpGrant grant) {
    _grants
      ..removeWhere((g) => g.operation == grant.operation)
      ..add(grant);
  }

  /// Действующий токен для [operation] или `null` (истёкшие удаляются).
  String? tokenFor(String operation) {
    final now = _clock.nowUtc();
    _grants.removeWhere((g) => !g.expiresAt.subtract(_skew).isAfter(now));
    for (final grant in _grants.reversed) {
      if (grant.covers(operation)) return grant.token;
    }
    return null;
  }

  /// Сервер отверг [token] — удалить его.
  void discard(String token) => _grants.removeWhere((g) => g.token == token);

  /// Выход / завершение / блокировка.
  void clear() => _grants.clear();

  /// Число действующих записей (для тестов).
  int get length => _grants.length;
}
