// RM-D-015 / EQ-DREST-15: регистрация (4 шага с «Привязкой» или 3) читает `features.customerSelfService`
// из `GET /settings/public` (через `publicCustomerSelfServiceProvider`), а не только флаг сборки.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

void main() {
  test('сервер выключил самообслуживание при флаге сборки true → регистрация без «Привязки»', () {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.fromMap(const <String, String>{
            'API_BASE_URL': 'https://api.test/api/v1',
            'FEATURE_CUSTOMER_SELF_SERVICE': 'true',
          }),
        ),
        publicCustomerSelfServiceProvider.overrideWithValue(false),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(customerSelfServiceProvider), isFalse);
  });

  test('до ответа сервера — флаг сборки', () {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.fromMap(const <String, String>{
            'API_BASE_URL': 'https://api.test/api/v1',
            'FEATURE_CUSTOMER_SELF_SERVICE': 'false',
          }),
        ),
        publicSettingsAutoRefreshProvider.overrideWithValue(false),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(customerSelfServiceProvider), isFalse);
  });
}
