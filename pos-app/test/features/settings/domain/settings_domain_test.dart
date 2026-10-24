// Домен SCR-42: предпроверка нового PIN (AC-UI-42-003; 09 §9.6), имя устройства (UI-42-016),
// секции `?section=`, длина PIN по виду пользователя, видимость по роли.
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/usecases/settings_pin_policy.dart';

void main() {
  group('SettingsPinPolicy', () {
    test('AC-UI-42-003: 123456 / 000000 / 654321 / год рождения отклоняются как слабые', () {
      for (final String pin in <String>['123456', '000000', '654321', '111111']) {
        expect(SettingsPinPolicy.check(pin, length: 6), NewPinIssue.weak, reason: pin);
      }
      expect(SettingsPinPolicy.check('199031', length: 6, birthYear: 1990), NewPinIssue.weak);
      expect(SettingsPinPolicy.check('1990', length: 4, birthYear: 1990), NewPinIssue.weak);
      expect(SettingsPinPolicy.check('582914', length: 6, birthYear: 1990), isNull);
      expect(SettingsPinPolicy.check('4829', length: 4), isNull);
    });

    test('длина по роли и только цифры', () {
      expect(SettingsPinPolicy.check('4829', length: 6), NewPinIssue.format);
      expect(SettingsPinPolicy.check('58291a', length: 6), NewPinIssue.format);
    });

    test('повтор: несовпадение → mismatch', () {
      expect(SettingsPinPolicy.confirm('582914', '582914'), isNull);
      expect(SettingsPinPolicy.confirm('582914', '582915'), NewPinIssue.mismatch);
    });
  });

  test('DeviceNameRule: 1…60 символов без управляющих', () {
    expect(DeviceNameRule.normalize('  Касса-1 '), 'Касса-1');
    expect(DeviceNameRule.normalize('   '), isNull);
    expect(DeviceNameRule.normalize('a' * 61), isNull);
    expect(DeviceNameRule.normalize('a\u0007b'), isNull);
    expect(DeviceNameRule.normalize('a' * 60), 'a' * 60);
  });

  test('SettingsSection: значения query section (02 SCR-42.6)', () {
    expect(SettingsSection.values.map((SettingsSection s) => s.value), <String>[
      'language',
      'security',
      'sessions',
      'scanner',
      'printer',
      'display',
      'about',
    ]);
    expect(SettingsSection.tryParse('sessions'), SettingsSection.sessions);
    expect(SettingsSection.tryParse('x'), isNull);
  });

  test('длина PIN: staff — 6, customer — 4; SettingsViewer', () {
    const LoginProtectionState staff = LoginProtectionState(
      userKind: UserKind.staff,
      pinSet: true,
      biometricsEnabled: false,
      support: BiometricSupport.unavailable,
      platformLabel: BiometricPlatformLabel.windows,
    );
    expect(staff.pinLength, 6);
    expect(staff.copyWith(pinSet: false).pinSet, isFalse);
    const LoginProtectionState customer = LoginProtectionState(
      userKind: UserKind.customer,
      pinSet: true,
      biometricsEnabled: true,
      support: BiometricSupport.cryptoLogin,
      platformLabel: BiometricPlatformLabel.android,
    );
    expect(customer.pinLength, 4);
    expect(customer.isStaff, isFalse);
    expect(const SettingsViewer(kind: UserKind.customer).isCustomer, isTrue);
    expect(const SettingsViewer(primaryRole: RoleCode.customer).isCustomer, isTrue);
    expect(const SettingsViewer(kind: UserKind.staff, primaryRole: RoleCode.cashier).isStaff, isTrue);
    expect(TextScaleOption.xlarge.factor, 1.3);
  });
}
