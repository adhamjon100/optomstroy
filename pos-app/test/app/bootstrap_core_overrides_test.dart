// `bootstrap` → `coreOverrides` (06 §6.10): метаданные клиента до `runApp`. Сбой secure storage или package_info не
// роняет запуск (без `clientMetaProvider` — Splash/«нет сессии»): PlatformException и MissingPluginException — только
// журнал. Только в браузере (веб-демо, ADR-113) — ещё UnsupportedError (flutter_secure_storage_web вне secure context)
// и сетевая ошибка `version.json` (один повтор). На Windows и Android UnsupportedError, в том числе UnimplementedError
// незарегистрированного плагина, и прочие исключения пробрасываются — причина видна до `runApp` (ревью R-01).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/client_meta.dart';

void main() {
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;
  setUp(() {
    records = <LogRecord>[];
    sub = Logger.root.onRecord.listen(records.add);
  });
  tearDown(() => sub.cancel());

  List<String> warnings() => <String>[
    for (final LogRecord r in records)
      if (r.loggerName == 'bootstrap' && r.level == Level.WARNING) r.message,
  ];

  test('метаданные загружены — clientMetaProvider переопределён', () async {
    const ClientMeta meta = ClientMeta(appVersion: '0.1.0+1', platform: ClientPlatform.windows, deviceId: 'd-1');
    final List<Override> overrides = await coreOverrides(() async => meta);
    final ProviderContainer container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    expect(container.read(clientMetaProvider).appVersion, '0.1.0+1');
    expect(warnings(), isEmpty);
  });

  test('браузер вне secure context: UnsupportedError — без переопределения, запись в журнал', () async {
    final List<Override> overrides = await coreOverrides(
      () async => throw UnsupportedError('FlutterSecureStorage requires a secure context'),
      isWeb: true,
    );
    expect(overrides, isEmpty);
    expect(warnings().single, contains('FlutterSecureStorage requires a secure context'));
  });

  test('Windows/Android: UnsupportedError и UnimplementedError пробрасываются, а не только в журнал', () async {
    await expectLater(
      coreOverrides(() async => throw UnimplementedError('getAll() has not been implemented.'), isWeb: false),
      throwsA(isA<UnimplementedError>()),
    );
    await expectLater(
      coreOverrides(() async => throw UnsupportedError('Socket'), isWeb: false),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      coreOverrides(() async => throw const _NetError('version.json'), isWeb: false),
      throwsA(isA<_NetError>()),
    );
    expect(warnings(), isEmpty);
  });

  test('браузер: UnimplementedError (плагин не зарегистрирован) тоже пробрасывается', () async {
    await expectLater(
      coreOverrides(() async => throw UnimplementedError('getAll() has not been implemented.'), isWeb: true),
      throwsA(isA<UnimplementedError>()),
    );
  });

  test('браузер: сетевая ошибка version.json — один повтор; удачный повтор даёт метаданные', () async {
    const ClientMeta meta = ClientMeta(appVersion: '0.1.0+1', platform: ClientPlatform.windows, deviceId: 'd-1');
    var calls = 0;
    final List<Override> overrides = await coreOverrides(() async {
      calls++;
      if (calls == 1) throw const _NetError('version.json');
      return meta;
    }, isWeb: true);
    expect(calls, 2);
    expect(overrides, hasLength(1));
    expect(warnings(), isEmpty);
  });

  test('браузер: сетевая ошибка и при повторе — без переопределения, запись в журнал, не исключение', () async {
    var calls = 0;
    final List<Override> overrides = await coreOverrides(() async {
      calls++;
      throw const _NetError('version.json');
    }, isWeb: true);
    expect(calls, 2);
    expect(overrides, isEmpty);
    expect(warnings().single, contains('_NetError'));
  });

  test('PlatformException и MissingPluginException — без переопределения, запись в журнал', () async {
    expect(await coreOverrides(() async => throw PlatformException(code: 'storage')), isEmpty);
    expect(await coreOverrides(() async => throw MissingPluginException('no plugin')), isEmpty);
    expect(warnings(), hasLength(2));
    expect(warnings().first, 'ClientMeta.load: storage');
  });
}

/// Сетевая ошибка `package:http` (`ClientException` — это [Exception]).
final class _NetError implements Exception {
  const _NetError(this.message);

  final String message;

  @override
  String toString() => '_NetError: $message';
}
