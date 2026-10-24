// Чтение claims access JWT без проверки подписи (09 §8.1) — только для UX клиента:
// заблаговременный refresh (`exp − now < 60 с`, 09 §8.3), тип пользователя для idle-блокировки,
// `sub` для владельца локальных черновиков. Решения безопасности принимает сервер.
// Claims без ПДн (ФИО/телефона в токене нет); сам токен никуда не пишется.
import 'dart:convert';

final class AccessTokenClaims {
  const AccessTokenClaims({this.subject, this.kind, this.sessionId, this.expiresAt, this.roles = const <String>[]});

  /// `sub` — `user_id`.
  final String? subject;

  /// `kind` — `staff` | `customer`.
  final String? kind;

  /// `sid`.
  final String? sessionId;

  /// `exp` (UTC).
  final DateTime? expiresAt;

  /// `roles[]`.
  final List<String> roles;

  /// Разбор payload JWS compact; не JWT или повреждён — `null`.
  static AccessTokenClaims? tryParse(String? token) {
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3 || parts[1].isEmpty) return null;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (payload is! Map<String, dynamic>) return null;
      final exp = payload['exp'];
      final roles = payload['roles'];
      return AccessTokenClaims(
        subject: payload['sub'] is String ? payload['sub'] as String : null,
        kind: payload['kind'] is String ? payload['kind'] as String : null,
        sessionId: payload['sid'] is String ? payload['sid'] as String : null,
        expiresAt:
            exp
                is num // money-double: allow — JSON-число → int (не деньги)
            ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
            : null,
        roles: roles is List ? roles.whereType<String>().toList(growable: false) : const <String>[],
      );
    } on FormatException {
      return null;
    }
  }

  /// До истечения осталось меньше [margin] (09 §8.3: refresh заранее при `exp − now < 60 с`).
  bool expiresWithin(Duration margin, DateTime nowUtc) {
    final exp = expiresAt;
    return exp != null && exp.difference(nowUtc) < margin;
  }

  @override
  String toString() => 'AccessTokenClaims(kind: $kind, exp: $expiresAt)';
}
