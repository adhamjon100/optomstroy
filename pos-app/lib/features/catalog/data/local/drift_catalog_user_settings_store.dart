// drift `settings` (07 §11.2) БД текущего пользователя — реализация [CatalogUserSettingsStore]
// (EQ-CAT-05, EQ-CAT-06). Строки `scope=user` удаляет `SessionLocalData.clearOnSessionEnd` (выход,
// `SESSION_REVOKED`, смена пользователя — 07 §11.4); строки `scope=device` остаются в файле пользователя.
// Чтение/запись после закрытия БД (смена пользователя во время запроса) не бросает: значение по умолчанию.
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_user_settings_store.dart';

final Logger _log = Logger('catalog.settings');

final class DriftCatalogUserSettingsStore implements CatalogUserSettingsStore {
  DriftCatalogUserSettingsStore(this._db, this._clock);

  final AppDatabase _db;
  final Clock _clock;

  @override
  Future<String?> read(String key) async {
    try {
      final SettingRow? row = await (_db.select(
        _db.localSettings,
      )..where(($LocalSettingsTable t) => t.key.equals(key))).getSingleOrNull();
      return row?.valueJson;
    } on Object catch (e) {
      _log.fine('чтение $key: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value, {required CatalogSettingScope scope}) async {
    try {
      await _db
          .into(_db.localSettings)
          .insertOnConflictUpdate(
            LocalSettingsCompanion.insert(
              key: key,
              valueJson: value,
              scope: scope.value,
              updatedAt: _clock.nowMillis(),
              dirty: const Value(false),
            ),
          );
    } on Object catch (e) {
      _log.fine('запись $key: ${e.runtimeType}');
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await (_db.delete(_db.localSettings)..where(($LocalSettingsTable t) => t.key.equals(key))).go();
    } on Object catch (e) {
      _log.fine('удаление $key: ${e.runtimeType}');
    }
  }
}
