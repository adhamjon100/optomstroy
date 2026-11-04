// Полоса «DEV · TEST DATA» (`EnvBanner`, 13 RM-C-008) — во всех сборках вне prod, кроме веб-демо (решение владельца
// 2026-10-31, 15 ADR-114 п. 9 (5); AC-ADR-114 (6); ревью RC-04, RP-04, RV-03):
// - веб-демо: конфигурация точки входа (`demoAppConfig`, константы профиля `env/web_demo.json`) — `ENV_BANNER=false`,
//   полосы нет, приложение начинается с верхнего края окна; переопределений демо по-прежнему три (T-DEMO-001);
// - dev-сборки Windows и Android (`AppConfig.fromEnvironment`, профили `env/dev.json`, `env/dev_proxy.json`,
//   `env/staging.json`) — полоса есть; ключа `ENV_BANNER` в профилях нет, а `fromEnvironment` его не читает, поэтому
//   снять полосу у этих сборок нельзя; prod — без полосы, как прежде.
// VM, синтетические данные, без сети.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/demo/demo_overrides.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/design_system/components/env_banner.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';

const String _origin = 'https://optomstroy-demo.example';

/// Строковые константы профиля сборки `env/<name>.json` (как `--dart-define-from-file`).
Map<String, String> _profile(String name) {
  final Object? json = jsonDecode(File('env/$name.json').readAsStringSync());
  return <String, String>{
    for (final MapEntry<String, dynamic> e in (json! as Map<String, dynamic>).entries) e.key: '${e.value}',
  };
}

/// Корень приложения с полосой по [config], как `App.builder`.
Widget _app(AppConfig config) => MaterialApp(
  theme: AppTheme.light(),
  home: EnvBanner(
    environmentCode: config.envBannerCode,
    child: const Scaffold(
      body: Align(alignment: Alignment.topLeft, child: Text('app-root')),
    ),
  ),
);

void main() {
  group('веб-демо — без полосы «DEV · TEST DATA»', () {
    test('конфигурация точки входа: ENV=dev из env/web_demo.json, ENV_BANNER=false, кода полосы нет', () {
      final Map<String, String> constants = _profile('web_demo');
      expect(constants['ENV'], 'dev', reason: 'веб-демо собирается с ENV=dev (ADR-113)');
      final AppConfig config = demoAppConfig(_origin, constants: constants);
      expect(config.environment, AppEnvironment.dev);
      expect(config.envBanner, isFalse);
      expect(config.envBannerCode, isNull);
      expect(config.apiBaseUrl.toString(), '$_origin/api/v1', reason: 'остальная конфигурация демо не меняется');
    });

    testWidgets('над приложением нет полосы, содержимое — у верхнего края окна', (tester) async {
      await tester.pumpWidget(_app(demoAppConfig(_origin, constants: _profile('web_demo'))));
      expect(find.byKey(EnvBanner.bannerKey), findsNothing);
      expect(find.textContaining('TEST DATA'), findsNothing);
      expect(tester.getTopLeft(find.text('app-root')).dy, 0);
    });
  });

  group('dev-сборки Windows и Android — полоса остаётся', () {
    for (final (String profile, String code) in const <(String, String)>[
      ('dev', 'dev'),
      ('dev_proxy', 'dev'),
      ('staging', 'staging'),
    ]) {
      test('env/$profile.json: без ключа ENV_BANNER, полоса «${code.toUpperCase()} · TEST DATA»', () {
        final Map<String, String> constants = _profile(profile);
        expect(constants.containsKey('ENV_BANNER'), isFalse, reason: 'снять полосу может только точка входа веб-демо');
        final AppConfig config = AppConfig.fromMap(constants);
        expect(config.envBanner, isTrue);
        expect(config.envBannerCode, code);
      });
    }

    test('константы сборки (`AppConfig.fromEnvironment`, как в lib/main.dart) — полоса есть', () {
      final AppConfig config = AppConfig.fromEnvironment();
      expect(config.isProd, isFalse);
      expect(config.envBanner, isTrue);
      expect(config.envBannerCode, config.environment.name);
    });

    testWidgets('над приложением полоса «DEV · TEST DATA», содержимое — под ней', (tester) async {
      await tester.pumpWidget(_app(AppConfig.fromMap(_profile('dev'))));
      expect(find.byKey(EnvBanner.bannerKey), findsOneWidget);
      expect(find.text(EnvBanner.labelFor('dev')), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('app-root')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byKey(EnvBanner.bannerKey)).dy),
      );
    });

    test('prod — без полосы; ENV_BANNER разбирается строго', () {
      expect(
        AppConfig.fromMap(const <String, String>{
          'ENV': 'prod',
          'API_BASE_URL': 'https://pos.example/api/v1',
        }).envBannerCode,
        isNull,
      );
      expect(AppConfig.fromMap(const <String, String>{'ENV': 'dev', 'ENV_BANNER': 'true'}).envBannerCode, 'dev');
      expect(
        () => AppConfig.fromMap(const <String, String>{'ENV': 'dev', 'ENV_BANNER': 'нет'}),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
