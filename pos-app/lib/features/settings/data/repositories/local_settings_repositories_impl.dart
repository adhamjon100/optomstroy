// Локальные настройки SCR-42: отображение (drift `settings(scope=device)`, 07 §11.2; UI-42-006/007/025) и
// «О приложении» (ClientMeta, заголовки версий; UI-42-008). Без ПДн.
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';

final Logger _log = Logger('settings.display');

/// Настройки отображения в таблице `settings` (ключ `display`, `scope=device`).
/// Без открытой БД (до входа) — только память процесса.
final class DisplayPreferencesRepositoryImpl implements DisplayPreferencesRepository {
  DisplayPreferencesRepositoryImpl(this._db, this._clock);

  /// Ключ строки `settings`.
  static const String key = 'display';

  final AppDatabase? _db;
  final Clock _clock;
  DisplayPreferences _memory = DisplayPreferences.defaults;

  static DisplayPreferences decode(String raw) {
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map) return DisplayPreferences.defaults;
      T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
          values.firstWhere((T v) => v.name == name, orElse: () => fallback);
      return DisplayPreferences(
        density: pick(DisplayDensity.values, j['density'], DisplayDensity.auto),
        textScale: pick(TextScaleOption.values, j['textScale'], TextScaleOption.system),
        reduceMotion: j['reduceMotion'] == true,
      );
    } on FormatException {
      return DisplayPreferences.defaults;
    }
  }

  static String encode(DisplayPreferences p) => jsonEncode(<String, Object?>{
    'density': p.density.name,
    'textScale': p.textScale.name,
    'reduceMotion': p.reduceMotion,
  });

  @override
  Future<DisplayPreferences> load() async {
    final AppDatabase? db = _db;
    if (db == null) return _memory;
    try {
      final SettingRow? row = await (db.select(
        db.localSettings,
      )..where(($LocalSettingsTable t) => t.key.equals(key))).getSingleOrNull();
      return _memory = row == null ? DisplayPreferences.defaults : decode(row.valueJson);
    } on Object catch (e) {
      _log.warning('чтение: ${e.runtimeType}');
      return _memory;
    }
  }

  @override
  Future<void> save(DisplayPreferences value) async {
    _memory = value;
    final AppDatabase? db = _db;
    if (db == null) return;
    await db
        .into(db.localSettings)
        .insertOnConflictUpdate(
          LocalSettingsCompanion.insert(
            key: key,
            valueJson: encode(value),
            scope: 'device',
            updatedAt: _clock.nowMillis(),
          ),
        );
  }
}

/// «О приложении» из [ClientMeta] и последних заголовков версий (AppVersionController).
final class AppAboutSourceImpl implements AppAboutSource {
  AppAboutSourceImpl({
    required ClientMeta? Function() meta,
    required ({String? min, String? recommended}) Function() versions,
  }) : _meta = meta,
       _versions = versions;

  final ClientMeta? Function() _meta;
  final ({String? min, String? recommended}) Function() _versions;

  @override
  AppAboutInfo current() {
    final ClientMeta? meta = _meta();
    final ({String? min, String? recommended}) v = _versions();
    final String? deviceId = meta?.deviceId;
    return AppAboutInfo(
      appVersion: meta?.appVersion ?? '—',
      platform: DevicePlatform.tryParse(meta?.platform?.name),
      deviceIdSuffix: deviceId == null || deviceId.isEmpty
          ? null
          : deviceId.substring(deviceId.length > 8 ? deviceId.length - 8 : 0),
      minVersion: v.min,
      recommendedVersion: v.recommended,
    );
  }
}
