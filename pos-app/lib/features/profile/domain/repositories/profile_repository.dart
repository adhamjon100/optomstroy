// Порт профиля SCR-41 (08 §4.3). Только онлайн. Выход, «выйти со всех устройств», блокировка — фича auth / core
// session; настройки SCR-42 — фича settings. Смена телефона — step-up (`X-Step-Up-Token` подставляет
// AuthInterceptor или явный [stepUpToken]). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';

abstract interface class ProfileRepository {
  /// `GET /me`.
  Future<Result<UserProfile>> me();

  /// `PATCH /me/profile`.
  Future<Result<ProfileData>> update(ProfilePatch patch, {String? idempotencyKey});

  /// `POST /me/phone/change/request` (step-up) → код на новый номер.
  Future<Result<PhoneChangeChallenge>> requestPhoneChange(String newPhoneE164, {String? stepUpToken});

  /// `POST /me/phone/change/confirm`.
  Future<Result<PhoneChangeResult>> confirmPhoneChange({required String challengeId, required String code});
}
