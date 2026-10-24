// FA-08 / RM-D-015: видимость вкладки «Привязки клиентов» SCR-45 берётся из `GET /settings/public`
// (`features.customerSelfService`), а не из флага сборки; до ответа сервера — флаг сборки (по умолчанию `true`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';

final class _Preset extends PublicSettingsController {
  _Preset(this.preset);

  final PublicSettingsSnapshot preset;

  @override
  PublicSettingsSnapshot build() => preset;
}

ProviderContainer _container(PublicSettingsSnapshot snapshot, {Map<String, String> env = const <String, String>{}}) {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      publicSettingsProvider.overrideWith(() => _Preset(snapshot)),
      appConfigProvider.overrideWithValue(AppConfig.fromMap(env)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

PublicSettingsSnapshot _server({required bool selfService}) => PublicSettingsSnapshot(
  settings: PublicSettings(features: PublicFeatures(customerSelfService: selfService)),
  source: PublicSettingsSource.network,
);

void main() {
  test('сервер features.customerSelfService=false → вкладка «Привязки» скрыта, хотя флаг сборки true', () {
    expect(_container(_server(selfService: false)).read(adminCustomerSelfServiceProvider), isFalse);
  });

  test('сервер true при флаге сборки false → true (сервер важнее)', () {
    final ProviderContainer c = _container(
      _server(selfService: true),
      env: const <String, String>{'FEATURE_CUSTOMER_SELF_SERVICE': 'false'},
    );
    expect(c.read(adminCustomerSelfServiceProvider), isTrue);
  });

  test('ответа сервера ещё нет → флаг сборки (по умолчанию true; false — если так собрано)', () {
    expect(_container(PublicSettingsSnapshot.initial).read(adminCustomerSelfServiceProvider), isTrue);
    expect(
      _container(
        PublicSettingsSnapshot.initial,
        env: const <String, String>{'FEATURE_CUSTOMER_SELF_SERVICE': 'false'},
      ).read(adminCustomerSelfServiceProvider),
      isFalse,
    );
  });
}
