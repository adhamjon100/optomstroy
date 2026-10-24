// AppConfig: API_BASE_URL, ENV, LOG_LEVEL, FEATURE_FLAGS через dart-define (06 §6.9).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';

void main() {
  test('по умолчанию (без dart-define): dev, локальный API, debug, флаги по умолчанию', () {
    final c = AppConfig.fromEnvironment();
    expect(c.environment, AppEnvironment.dev);
    expect(c.apiBaseUrl.toString(), AppConfig.defaultDevBaseUrl);
    expect(c.logLevel, LogLevel.debug);
    expect(c.isProd, isFalse);
    expect(c.isEnabled(FeatureFlag.faceScan), isFalse);
    expect(c.isEnabled(FeatureFlag.customerSelfService), isTrue);
    expect(c.isEnabled('unknown_flag'), isFalse);
  });

  test('prod: https обязателен, косая черта в конце убирается, info по умолчанию', () {
    final c = AppConfig.fromMap(const {'ENV': 'prod', 'API_BASE_URL': 'https://api.example.kg/api/v1/'});
    expect(c.isProd, isTrue);
    expect(c.apiBaseUrl.toString(), 'https://api.example.kg/api/v1');
    expect(c.logLevel, LogLevel.info);
    expect(() => AppConfig.fromMap(const {'ENV': 'prod'}), throwsA(isA<ConfigException>()));
    expect(
      () => AppConfig.fromMap(const {'ENV': 'prod', 'API_BASE_URL': 'http://api.example.kg/api/v1'}),
      throwsA(isA<ConfigException>()),
    );
  });

  test('ENVIRONMENT — синоним ENV; LOG_LEVEL; ошибки значений', () {
    expect(AppConfig.fromMap(const {'ENVIRONMENT': 'staging', 'LOG_LEVEL': 'Warning'}).logLevel, LogLevel.warning);
    expect(AppConfig.fromMap(const {'ENVIRONMENT': 'staging'}).environment, AppEnvironment.staging);
    expect(() => AppConfig.fromMap(const {'ENV': 'stage'}), throwsA(isA<ConfigException>()));
    // C-MN-04: профили — ровно значения APP_ENV (dev | staging | prod); прежнего «test» нет
    expect(AppEnvironment.values.map((e) => e.name), ['dev', 'staging', 'prod']);
    expect(() => AppConfig.fromMap(const {'ENV': 'test'}), throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const {'LOG_LEVEL': 'verbose'}), throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const {'API_BASE_URL': 'ftp://x'}), throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const {'API_BASE_URL': 'not a url'}), throwsA(isA<ConfigException>()));
    expect(const ConfigException('m').toString(), 'ConfigException: m');
  });

  test('C-MN-04: prod отвергает LOG_LEVEL=debug и FEATURE_FACE_SCAN=true (в т. ч. через FEATURE_FLAGS)', () {
    const base = {'ENV': 'prod', 'API_BASE_URL': 'https://api.example.kg/api/v1'};
    expect(() => AppConfig.fromMap(const {...base, 'LOG_LEVEL': 'debug'}), throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const {...base, 'FEATURE_FACE_SCAN': 'true'}), throwsA(isA<ConfigException>()));
    expect(() => AppConfig.fromMap(const {...base, 'FEATURE_FLAGS': 'face_scan'}), throwsA(isA<ConfigException>()));
    expect(AppConfig.fromMap(const {...base, 'LOG_LEVEL': 'warning'}).logLevel, LogLevel.warning);
    // вне prod — допустимо
    expect(
      AppConfig.fromMap(const {
        'ENV': 'staging',
        'FEATURE_FACE_SCAN': 'true',
        'LOG_LEVEL': 'debug',
      }).isEnabled(FeatureFlag.faceScan),
      isTrue,
    );
  });

  test('FEATURE_FLAGS и отдельные FEATURE_* (последние приоритетнее)', () {
    expect(AppConfig.parseFeatureFlags('a=true, b=off,c, ,D=1'), {'a': true, 'b': false, 'c': true, 'd': true});
    expect(() => AppConfig.parseFeatureFlags('=true'), throwsA(isA<ConfigException>()));
    expect(() => AppConfig.parseFeatureFlags('a=maybe'), throwsA(isA<ConfigException>()));
    final c = AppConfig.fromMap(const {
      'FEATURE_FLAGS': 'face_scan=true,new_catalog',
      'FEATURE_FACE_SCAN': 'false',
      'FEATURE_CUSTOMER_SELF_SERVICE': 'no',
    });
    expect(c.isEnabled(FeatureFlag.faceScan), isFalse);
    expect(c.isEnabled(FeatureFlag.customerSelfService), isFalse);
    expect(c.isEnabled('new_catalog'), isTrue);
    expect(() => c.features['x'] = true, throwsUnsupportedError);
  });
}
