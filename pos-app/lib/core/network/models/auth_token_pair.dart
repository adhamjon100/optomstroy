// DTO `AuthTokenPair` — ответ `POST /auth/refresh` (08 §4.1.3).
// toString без значений токенов (NFR-LOG-001).
import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_token_pair.freezed.dart';
part 'auth_token_pair.g.dart';

@Freezed(toStringOverride: false)
abstract class AuthTokenPair with _$AuthTokenPair {
  const factory AuthTokenPair({
    required String accessToken,
    required int accessExpiresIn,
    required String refreshToken,
    required DateTime refreshExpiresAt,
    required String sid,
    int? permissionsVersion,
  }) = _AuthTokenPair;

  const AuthTokenPair._();

  factory AuthTokenPair.fromJson(Map<String, dynamic> json) => _$AuthTokenPairFromJson(json);

  @override
  String toString() => 'AuthTokenPair(***)';
}
