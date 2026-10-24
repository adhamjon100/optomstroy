// Конфигурация окружения через --dart-define / --dart-define-from-file
// (06 §6.9, R3 §8; SRC-D-028). Секретов в приложении нет; envied отклонён.
//
// Ключи:
//   API_BASE_URL   — базовый URL API с `/api/v1` (08 §2.1; Q-032);
//   ENV            — dev | staging | prod — ровно значения APP_ENV сервера (16 §4.3; RM-C-009: тестовый
//                    контур — staging, CI — dev); синоним ENVIRONMENT из 06 §6.9;
//   LOG_LEVEL      — debug | info | warning | error (по умолчанию debug в dev, info иначе);
//   FEATURE_FLAGS  — `name=true,other=false` или `name,other` (включённые);
//   FEATURE_FACE_SCAN, FEATURE_CUSTOMER_SELF_SERVICE — отдельные флаги 06 §6.9,
//                    имеют приоритет над FEATURE_FLAGS. Серверные флаги
//                    (`GET /settings/public` features) важнее локальных;
//   APP_DATA_DIR   — только dev/staging-сборки (integration_test, машина разработки): абсолютный каталог, куда
//                    пишутся данные приложения (БД drift `pos_<user_id>.db`, файл secure storage, кэш) вместо
//                    каталога ОС (%APPDATA% на Windows). В prod ключ игнорируется. Значение — только константа
//                    сборки (`--dart-define`), не пользовательский ввод.
import 'package:path/path.dart' as p;

/// Окружение сборки — профили `APP_ENV` (dev | staging | prod, 16 §4.3; ревью C-MN-04).
enum AppEnvironment {
  dev,
  staging,
  prod;

  static AppEnvironment? tryParse(String value) {
    for (final env in values) {
      if (env.name == value.trim().toLowerCase()) return env;
    }
    return null;
  }
}

/// Ошибка конфигурации сборки (неверный dart-define).
final class ConfigException implements Exception {
  const ConfigException(this.message);

  final String message;

  @override
  String toString() => 'ConfigException: $message';
}

/// Известные клиентские флаги (06 §6.9).
abstract final class FeatureFlag {
  /// SCR-05 «Скан лица» — R2, по умолчанию выключен (D-14).
  static const String faceScan = 'face_scan';

  /// Самостоятельная регистрация клиента (CUSTOMER_SELF_SERVICE, ядро §24.2).
  static const String customerSelfService = 'customer_self_service';

  static const Map<String, bool> defaults = {faceScan: false, customerSelfService: true};
}

/// Неизменяемая конфигурация приложения.
final class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.environment,
    required this.logLevel,
    required this.features,
    this.appDataDir,
  });

  /// Значения, переданные при сборке (`--dart-define-from-file=config/<env>.json`).
  factory AppConfig.fromEnvironment() => AppConfig.fromMap(const {
    'API_BASE_URL': String.fromEnvironment('API_BASE_URL'),
    'ENV': String.fromEnvironment('ENV'),
    'ENVIRONMENT': String.fromEnvironment('ENVIRONMENT'),
    'LOG_LEVEL': String.fromEnvironment('LOG_LEVEL'),
    'FEATURE_FLAGS': String.fromEnvironment('FEATURE_FLAGS'),
    'FEATURE_FACE_SCAN': String.fromEnvironment('FEATURE_FACE_SCAN'),
    'FEATURE_CUSTOMER_SELF_SERVICE': String.fromEnvironment('FEATURE_CUSTOMER_SELF_SERVICE'),
    'APP_DATA_DIR': String.fromEnvironment('APP_DATA_DIR'),
  });

  /// Разбор словаря значений; пустая строка = ключ не задан.
  factory AppConfig.fromMap(Map<String, String> values) {
    String? read(String key) {
      final value = values[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final envRaw = read('ENV') ?? read('ENVIRONMENT') ?? AppEnvironment.dev.name;
    final environment =
        AppEnvironment.tryParse(envRaw) ?? (throw ConfigException('ENV: неизвестное значение "$envRaw"'));

    final baseUrl = read('API_BASE_URL') ?? (environment == AppEnvironment.prod ? null : defaultDevBaseUrl);
    if (baseUrl == null) throw const ConfigException('API_BASE_URL обязателен для prod');
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty || !(uri.isScheme('https') || uri.isScheme('http'))) {
      throw ConfigException('API_BASE_URL: некорректный URL "$baseUrl"');
    }
    // 08 §2.1: только HTTPS; HTTP допустим лишь для локальной разработки.
    if (environment == AppEnvironment.prod && !uri.isScheme('https')) {
      throw const ConfigException('API_BASE_URL: в prod допустим только https');
    }

    final logRaw = read('LOG_LEVEL') ?? (environment == AppEnvironment.dev ? 'debug' : 'info');
    final logLevel = LogLevel.tryParse(logRaw) ?? (throw ConfigException('LOG_LEVEL: неизвестное значение "$logRaw"'));
    // 06 §6.7, 11 SEC-061: debug-логи — только вне prod.
    if (environment == AppEnvironment.prod && logLevel == LogLevel.debug) {
      throw const ConfigException('LOG_LEVEL: debug запрещён в prod');
    }

    final features = Map<String, bool>.of(FeatureFlag.defaults)..addAll(parseFeatureFlags(read('FEATURE_FLAGS') ?? ''));
    for (final (key, flag) in const [
      ('FEATURE_FACE_SCAN', FeatureFlag.faceScan),
      ('FEATURE_CUSTOMER_SELF_SERVICE', FeatureFlag.customerSelfService),
    ]) {
      final raw = read(key);
      if (raw != null) features[flag] = _parseBool(raw, key);
    }
    // SCR-05 «Скан лица» — R2 (D-14, Q-003): в prod-сборке R1 включение запрещено (ревью C-MN-04).
    if (environment == AppEnvironment.prod && (features[FeatureFlag.faceScan] ?? false)) {
      throw const ConfigException('FEATURE_FACE_SCAN: true запрещено в prod (R2, D-14)');
    }

    return AppConfig(
      apiBaseUrl: Uri.parse(baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl),
      environment: environment,
      logLevel: logLevel,
      features: Map.unmodifiable(features),
      // prod: ключ игнорируется — данные только в каталоге ОС.
      appDataDir: environment == AppEnvironment.prod ? null : parseAppDataDir(read('APP_DATA_DIR')),
    );
  }

  /// `APP_DATA_DIR`: абсолютный путь без сегментов `..` (Windows `D:/x`, `D:\x` или POSIX `/x`), нормализованный;
  /// `null` — не задан. Относительный путь, путь без буквы диска на Windows-стиле или `..` — [ConfigException].
  static String? parseAppDataDir(String? raw) {
    if (raw == null) return null;
    final bool drive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw);
    final p.Context ctx = drive ? p.windows : p.posix;
    if (!(drive || raw.startsWith('/')) || raw.contains('\u0000')) {
      throw ConfigException('APP_DATA_DIR: ожидается абсолютный путь, получено "$raw"');
    }
    if (ctx.split(raw).contains('..')) throw ConfigException('APP_DATA_DIR: сегмент ".." запрещён ("$raw")');
    return ctx.normalize(raw);
  }

  /// Локальный backend разработчика (pos-api слушает :3000, infra/README.md).
  static const String defaultDevBaseUrl = 'http://localhost:3000/api/v1';

  /// `FEATURE_FLAGS`: `a=true,b=false` или `a,b` (перечисленные без значения — включены).
  static Map<String, bool> parseFeatureFlags(String raw) {
    final result = <String, bool>{};
    for (final item in raw.split(',')) {
      final part = item.trim();
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final name = (eq < 0 ? part : part.substring(0, eq)).trim().toLowerCase();
      if (name.isEmpty) throw ConfigException('FEATURE_FLAGS: пустое имя флага в "$part"');
      result[name] = eq < 0 || _parseBool(part.substring(eq + 1), 'FEATURE_FLAGS.$name');
    }
    return result;
  }

  final Uri apiBaseUrl;
  final AppEnvironment environment;
  final LogLevel logLevel;
  final Map<String, bool> features;

  /// Каталог данных приложения для dev/staging-сборок (`APP_DATA_DIR`); в prod всегда `null`.
  final String? appDataDir;

  bool get isProd => environment == AppEnvironment.prod;

  /// Флаг включён (неизвестный флаг — выключен).
  bool isEnabled(String flag) => features[flag] ?? false;
}

/// Уровень логирования (debug — только dev, 06 §6.7).
enum LogLevel {
  debug,
  info,
  warning,
  error;

  static LogLevel? tryParse(String value) {
    for (final level in values) {
      if (level.name == value.trim().toLowerCase()) return level;
    }
    return null;
  }
}

bool _parseBool(String raw, String key) => switch (raw.trim().toLowerCase()) {
  'true' || '1' || 'yes' || 'on' => true,
  'false' || '0' || 'no' || 'off' => false,
  _ => throw ConfigException('$key: ожидается true/false, получено "$raw"'),
};
