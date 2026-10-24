// Глобальные состояния поверх навигации:
// - EnvBanner — маркировка тестовых данных вне prod (RM-C-008, ревью C-MJ-07);
// - SCR-90 «Требуется обновление» (426 → блокирующий экран) и мягкий баннер рекомендуемой версии
//   (RM-C-015 п. 3, ревью C-MJ-08).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/app.dart';
import 'package:optomstroy/app/global_states/app_version_gate.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/design_system/components/env_banner.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';

import '../support/fake_backend_health.dart';

const ClientMeta _meta = ClientMeta(
  appVersion: '1.2.0+40',
  platform: ClientPlatform.android,
  deviceId: '3f2b8c1e-5d4a-4b6c-9e7f-0a1b2c3d4e5f',
);

AppConfig _config(String env) => AppConfig.fromMap({'ENV': env, 'API_BASE_URL': 'https://api.example.kg/api/v1'});

Widget _app(ProviderContainer container) => UncontrolledProviderScope(container: container, child: const App());

ProviderContainer _container({String env = 'prod', bool withMeta = true}) {
  final container = ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(_config(env)),
      backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe()),
      if (withMeta) clientMetaProvider.overrideWithValue(_meta),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('EnvBanner (RM-C-008)', () {
    for (final env in ['dev', 'staging']) {
      testWidgets('$env: над приложением полоса «${env.toUpperCase()} · TEST DATA»', (tester) async {
        await tester.pumpWidget(_app(_container(env: env)));
        await tester.pumpAndSettle();
        expect(find.byKey(EnvBanner.bannerKey), findsOneWidget);
        expect(find.text(EnvBanner.labelFor(env)), findsOneWidget);
        expect(find.byKey(NoSessionScreen.screenKey), findsOneWidget); // приложение работает под полосой
      });
    }

    testWidgets('prod: баннера нет', (tester) async {
      await tester.pumpWidget(_app(_container()));
      await tester.pumpAndSettle();
      expect(find.byKey(EnvBanner.bannerKey), findsNothing);
      expect(find.textContaining('TEST DATA'), findsNothing);
      expect(find.byKey(NoSessionScreen.screenKey), findsOneWidget);
    });
  });

  group('SCR-90 и мягкий баннер версии (RM-C-015 п. 3)', () {
    testWidgets('ответ 426 → блокирующий экран SCR-90 с минимальной версией; «Назад» не уводит', (tester) async {
      final container = _container();
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsNothing);

      // То же, что делает AppVersionInterceptor при 426 APP_UPDATE_REQUIRED.
      await container
          .read(appVersionControllerProvider)
          .onUpdateRequired(minHeader: 'android=1.3.0', minVersionBody: '1.3.0');
      await tester.pumpAndSettle();

      expect(find.byKey(UpdateRequiredScreen.screenKey), findsOneWidget);
      expect(find.text('Требуется обновление приложения'), findsOneWidget);
      expect(find.text('Установите версию 1.3.0 или новее, чтобы продолжить работу'), findsOneWidget);
      expect(find.byKey(NoSessionScreen.screenKey), findsNothing); // приложение недоступно
      expect(find.byKey(UpdateRequiredScreen.updateButtonKey), findsNothing); // storeUrl нет — только инструкция

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsOneWidget);

      // Заголовки следующих ответов блокировку не снимают.
      await container.read(appVersionControllerProvider).onHeaders(minHeader: 'android=1.3.0');
      await tester.pumpAndSettle();
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsOneWidget);
    });

    testWidgets('storeUrl из тела 426 (https) → кнопка «Обновить» открывает ссылку', (tester) async {
      final opened = <Uri>[];
      final container = _container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _GateHost(onOpen: (url) async => opened.add(url)),
        ),
      );
      await container
          .read(appVersionControllerProvider)
          .onUpdateRequired(minHeader: 'android=1.3.0', storeUrl: 'https://play.google.com/store/apps/details?id=x');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(UpdateRequiredScreen.updateButtonKey));
      expect(opened, [Uri.parse('https://play.google.com/store/apps/details?id=x')]);
    });

    testWidgets('версия ниже X-Recommended-App-Version → мягкий баннер без блокировки; «Позже» скрывает', (
      tester,
    ) async {
      final container = _container();
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      await container
          .read(appVersionControllerProvider)
          .onHeaders(minHeader: 'android=1.2.0', recommendedHeader: 'android=1.4.0');
      await tester.pumpAndSettle();

      expect(find.byKey(UpdateAvailableBanner.bannerKey), findsOneWidget);
      expect(find.text('Доступна новая версия приложения'), findsOneWidget);
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsNothing);
      expect(find.byKey(NoSessionScreen.screenKey), findsOneWidget); // работа продолжается

      await tester.tap(find.text('Позже'));
      await tester.pumpAndSettle();
      expect(find.byKey(UpdateAvailableBanner.bannerKey), findsNothing);
    });

    testWidgets('без ClientMeta (bootstrap не прочитал метаданные) — ограничений версии нет', (tester) async {
      await tester.pumpWidget(_app(_container(withMeta: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(UpdateRequiredScreen.screenKey), findsNothing);
      expect(find.byKey(NoSessionScreen.screenKey), findsOneWidget);
    });
  });
}

/// Хост гейта с темой и локализацией приложения, но без роутера (проверка кнопки storeUrl).
class _GateHost extends StatelessWidget {
  const _GateHost({required this.onOpen});

  final StoreUrlOpener onOpen;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light(),
    locale: App.defaultLocale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: AppVersionGate(openStoreUrl: onOpen, child: const SizedBox()),
  );
}
