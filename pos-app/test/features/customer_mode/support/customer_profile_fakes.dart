// Фейк профиля клиента-покупателя (`GET /me`, 08 §4.3) для тестов режима клиента (RM-G-014). Синтетические данные.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';

/// Подтверждённая привязка к своей карточке 1С.
const ProfileCustomerLink confirmedLink = ProfileCustomerLink(
  status: ProfileLinkStatus.confirmed,
  linkId: 'l-1',
  customerId: 'c-own',
  displayName: 'ОсОО «Азамат Строй»',
  displayNameMasked: 'ОсОО «Аза***»',
);

/// Предложенная привязка (маска, без `customerId`).
const ProfileCustomerLink proposedLink = ProfileCustomerLink(
  status: ProfileLinkStatus.proposed,
  linkId: 'l-1',
  displayNameMasked: 'ОсОО «Аза***»',
);

/// Конфликт (несколько карточек с номером).
const ProfileCustomerLink conflictLink = ProfileCustomerLink(status: ProfileLinkStatus.conflict, linkId: 'l-1');

/// `Me` клиента-покупателя.
UserProfile customerMe({ProfileCustomerLink? link}) => UserProfile(
  id: 'cust-user',
  kind: UserKind.customer,
  status: UserStatus.active,
  roles: const <RoleCode>[RoleCode.customer],
  permissions: const <String>{'order.read.own', 'cart.manage.own'},
  permissionsVersion: 1,
  profile: const ProfileData(fullName: 'Азамат Бекович', phoneE164: '+996700123456', rowVersion: 2),
  customerLink: link,
  session: ProfileSession(deviceName: 'Pixel 7', createdAt: DateTime.utc(2026, 10, 22, 3, 12)),
);

/// Фейк порта профиля.
final class FakeCustomerProfileRepository implements ProfileRepository {
  FakeCustomerProfileRepository(this.profile);

  UserProfile profile;

  /// Ошибка `GET /me` (`null` — успех).
  Failure? failure;
  int meCalls = 0;

  @override
  Future<Result<UserProfile>> me() async {
    meCalls++;
    final Failure? f = failure;
    return f == null ? Success<UserProfile>(profile) : FailureResult<UserProfile>(f);
  }

  @override
  Future<Result<ProfileData>> update(ProfilePatch patch, {String? idempotencyKey}) async =>
      Success<ProfileData>(ProfileData(fullName: patch.fullName, rowVersion: patch.rowVersion + 1));

  @override
  Future<Result<PhoneChangeChallenge>> requestPhoneChange(String newPhoneE164, {String? stepUpToken}) async =>
      const Success<PhoneChangeChallenge>(
        PhoneChangeChallenge(challengeId: 'ch-1', resendAfterSec: 60, otpTtlSec: 300),
      );

  @override
  Future<Result<PhoneChangeResult>> confirmPhoneChange({required String challengeId, required String code}) async =>
      const Success<PhoneChangeResult>(PhoneChangeResult(phoneE164: '+996700123456', sessionsRevoked: true));
}
