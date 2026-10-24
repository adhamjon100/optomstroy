// APP_DATA_DIR (lib/core/config/app_data_directory.dart): dev/staging-сборка переносит данные приложения (drift,
// secure storage, кэш) в каталог-константу сборки; в prod ключ игнорируется — подмены path_provider нет.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

final class _OsPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => 'C:/Users/u/AppData/Roaming/app';

  @override
  Future<String?> getDownloadsPath() async => 'C:/Users/u/Downloads';
}

void main() {
  late PathProviderPlatform original;
  setUp(() {
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _OsPaths();
  });
  tearDown(() => PathProviderPlatform.instance = original);

  const Map<String, String> prod = {'ENV': 'prod', 'API_BASE_URL': 'https://api.example.kg/api/v1'};

  test('разбор: абсолютные пути Windows/POSIX нормализуются; относительный, без диска и ".." — ошибка', () {
    expect(AppConfig.parseAppDataDir(null), isNull);
    expect(AppConfig.parseAppDataDir('D:/optomstroy/.tmp/appdata'), r'D:\optomstroy\.tmp\appdata');
    expect(AppConfig.parseAppDataDir(r'D:\x\.\y\'), r'D:\x\y');
    expect(AppConfig.parseAppDataDir('/var/tmp/app/'), '/var/tmp/app');
    for (final String bad in <String>['appdata', './x', r'\x', 'D:x', 'D:/x/../y', '/a/../b', '~/x']) {
      expect(() => AppConfig.parseAppDataDir(bad), throwsA(isA<ConfigException>()), reason: bad);
    }
    expect(AppConfig.fromMap(const {'APP_DATA_DIR': 'D:/a'}).appDataDir, r'D:\a');
    expect(AppConfig.fromMap(const {'ENV': 'staging', 'APP_DATA_DIR': '/srv/a'}).appDataDir, '/srv/a');
    expect(() => AppConfig.fromMap(const {'APP_DATA_DIR': 'rel'}), throwsA(isA<ConfigException>()));
    expect(AppConfig.fromEnvironment().appDataDir, isNull, reason: 'unit-тесты собираются без APP_DATA_DIR');
  });

  test('prod: APP_DATA_DIR игнорируется (даже неверный), подмены path_provider нет', () async {
    final AppConfig c = AppConfig.fromMap(const {...prod, 'APP_DATA_DIR': 'D:/optomstroy/.tmp/appdata'});
    expect(c.appDataDir, isNull);
    expect(AppConfig.fromMap(const {...prod, 'APP_DATA_DIR': 'rel/../x'}).appDataDir, isNull);
    // Даже сконструированный вручную prod-конфиг с каталогом не применяется.
    final AppConfig forged = AppConfig(
      apiBaseUrl: Uri.parse('https://api.example.kg/api/v1'),
      environment: AppEnvironment.prod,
      logLevel: LogLevel.info,
      features: const {},
      appDataDir: 'D:/evil',
    );
    expect(AppDataDirectory.apply(c), isFalse);
    expect(AppDataDirectory.apply(forged), isFalse);
    expect(PathProviderPlatform.instance, isA<_OsPaths>());
    expect((await getApplicationSupportDirectory()).path, 'C:/Users/u/AppData/Roaming/app');
  });

  test(
    'dev: каталоги приложения — подкаталоги APP_DATA_DIR (создаются), «Загрузки» — от ОС; повтор идемпотентен',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync('app_data_dir_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final String root = AppConfig.parseAppDataDir(p.absolute(tmp.path))!;
      final AppConfig dev = AppConfig.fromMap({'APP_DATA_DIR': tmp.path});
      expect(dev.appDataDir, root);

      expect(AppDataDirectory.apply(dev), isTrue);
      final PathProviderPlatform redirected = PathProviderPlatform.instance;
      expect(redirected, isA<RedirectedPathProvider>());
      final Directory support = await getApplicationSupportDirectory();
      expect(support.path, p.join(root, RedirectedPathProvider.support));
      expect(support.existsSync(), isTrue);
      expect((await getApplicationDocumentsDirectory()).path, p.join(root, RedirectedPathProvider.documents));
      expect((await getApplicationCacheDirectory()).path, p.join(root, RedirectedPathProvider.cache));
      expect((await getTemporaryDirectory()).path, p.join(root, RedirectedPathProvider.temporary));
      expect((await getDownloadsDirectory())!.path, 'C:/Users/u/Downloads');

      // Перезапуск приложения (integration_test вызывает bootstrap повторно) — тот же экземпляр.
      expect(AppDataDirectory.apply(dev), isTrue);
      expect(identical(PathProviderPlatform.instance, redirected), isTrue);
      // Другой каталог — новая подмена поверх исходной платформы, не поверх прежней подмены.
      final Directory other = Directory(p.join(tmp.path, 'other'));
      expect(AppDataDirectory.apply(AppConfig.fromMap({'APP_DATA_DIR': other.path})), isTrue);
      final RedirectedPathProvider again = PathProviderPlatform.instance as RedirectedPathProvider;
      expect(again.delegate, isA<_OsPaths>());
      expect((await getApplicationSupportDirectory()).path, startsWith(again.root));
    },
  );

  test('без APP_DATA_DIR — подмены нет', () {
    expect(AppDataDirectory.apply(AppConfig.fromMap(const {})), isFalse);
    expect(PathProviderPlatform.instance, isA<_OsPaths>());
  });
}
