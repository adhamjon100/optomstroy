// Правила формы приглашения (UI-45-009, 02 SCR-45.8), аварийного кода (UI-45-024), поиска (UI-45-002).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';

void main() {
  final today = DateTime(2026, 10, 22);

  group('InvitationRules', () {
    Set<InvitationDraftError> v({
      String? phone = '+996700000007',
      RoleCode? role = RoleCode.seller,
      String name = '',
      DateTime? expires,
    }) => InvitationRules.validate(phoneE164: phone, role: role, fullName: name, expiresAt: expires, today: today);

    test('валидный черновик; ФИО необязательно', () => expect(v(), isEmpty));

    test('телефон: 9 цифр после +996', () {
      expect(v(phone: null), {InvitationDraftError.phone});
      expect(v(phone: '+99670000000'), {InvitationDraftError.phone});
    });

    test('роль обязательна; owner/admin/customer/integration приглашением не выдаются (AC-UI-45-020)', () {
      expect(v(role: null), {InvitationDraftError.role});
      for (final r in [RoleCode.owner, RoleCode.admin, RoleCode.customer, RoleCode.integration]) {
        expect(v(role: r), {InvitationDraftError.role}, reason: r.value);
      }
      expect(invitableRoles, [RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller]);
    });

    test('ФИО: 2…150 символов, если указано', () {
      expect(v(name: 'А'), {InvitationDraftError.fullName});
      expect(v(name: 'А' * 151), {InvitationDraftError.fullName});
      expect(v(name: 'Ли'), isEmpty);
    });

    test('срок: по умолчанию +30 дней; допустимо 1…90 дней', () {
      expect(InvitationRules.defaultExpiry(today), DateTime(2026, 11, 21));
      expect(v(expires: today), {InvitationDraftError.expiry});
      expect(v(expires: today.add(const Duration(days: 1))), isEmpty);
      expect(v(expires: today.add(const Duration(days: 90))), isEmpty);
      expect(v(expires: today.add(const Duration(days: 91))), {InvitationDraftError.expiry});
    });
  });

  group('EmergencyCodeRules', () {
    test('причина обязательна; комментарий 5…200, обязателен при other', () {
      expect(EmergencyCodeRules.isValid(null, ''), isFalse);
      expect(EmergencyCodeRules.isValid(EmergencyCodeReason.smsUnavailable, ''), isTrue);
      expect(EmergencyCodeRules.isValid(EmergencyCodeReason.other, ''), isFalse);
      expect(EmergencyCodeRules.isValid(EmergencyCodeReason.other, 'абв'), isFalse);
      expect(EmergencyCodeRules.isValid(EmergencyCodeReason.other, 'потерял телефон'), isTrue);
      expect(EmergencyCodeRules.isValid(EmergencyCodeReason.simLost, 'x' * 201), isFalse);
    });

    test('toString не раскрывает код', () {
      final code = EmergencyLoginCode(code: '482913', expiresAt: DateTime.utc(2026), phoneMasked: '+996 7** *** *01');
      expect(code.toString(), isNot(contains('482913')));
    });
  });

  group('AdminUsersQuery.effectiveQuery (≥ 2 букв или ≥ 3 цифр)', () {
    test('короткие запросы не отправляются', () {
      expect(const AdminUsersQuery(q: 'И').effectiveQuery, isNull);
      expect(const AdminUsersQuery(q: '70').effectiveQuery, isNull);
      expect(const AdminUsersQuery(q: '  ').effectiveQuery, isNull);
    });

    test('имя и часть телефона «700 000» отправляются (AC-UI-45-002)', () {
      expect(const AdminUsersQuery(q: 'Ив').effectiveQuery, 'Ив');
      expect(const AdminUsersQuery(q: '700 000').effectiveQuery, '700 000');
    });

    test('toString не содержит текст поиска (ПДн)', () {
      expect(const AdminUsersQuery(q: '700 000 01').toString(), isNot(contains('700')));
    });
  });
}
