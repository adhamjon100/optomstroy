// `settings` — настройки интерфейса (07 §11.2): `scope=user` — на пользователя (файл БД пользователя; очищаются при
// выходе/смене пользователя, 07 §11.4), `scope=device` — на устройство. EQ-CAT-05 (вид каталога «на пользователя и
// класс окна», 02 SCR-10.4.C): ключи `catalog.view.<windowClass>`, `catalog.sort`, … пишет фича catalog
// (`DriftCatalogUserSettingsStore`); этот DAO — общий доступ для прочих фич (корзина: склад, режим печати SCR-21).
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';

/// Область настройки (`settings.scope`).
enum SettingScope {
  user('user'),
  device('device');

  const SettingScope(this.value);

  final String value;
}

/// Доступ к `settings` БД текущего пользователя.
final class SettingsDao {
  SettingsDao(this._db);

  final AppDatabase _db;

  /// Ключ вида каталога для класса окна (EQ-CAT-05): `catalog.view.compact|medium|expanded|large`.
  static String catalogViewKey(String windowClass) => 'catalog.view.$windowClass';

  /// JSON-значение ключа или `null`.
  Future<String?> read(String key) async =>
      (await (_db.select(_db.localSettings)..where((t) => t.key.equals(key))).getSingleOrNull())?.valueJson;

  /// Изменения значения ключа.
  Stream<String?> watch(String key) => (_db.select(
    _db.localSettings,
  )..where((t) => t.key.equals(key))).watchSingleOrNull().map((SettingRow? r) => r?.valueJson);

  /// Записать JSON-значение. [dirty] — значение ещё не отправлено в `PUT /me/settings` (outbox `profile.settings`).
  Future<void> write(
    String key,
    String valueJson, {
    required SettingScope scope,
    required int nowMs,
    bool dirty = false,
  }) => _db
      .into(_db.localSettings)
      .insertOnConflictUpdate(
        LocalSettingsCompanion.insert(
          key: key,
          valueJson: valueJson,
          scope: scope.value,
          updatedAt: nowMs,
          dirty: Value(dirty),
        ),
      );

  /// Удалить ключ.
  Future<void> remove(String key) => (_db.delete(_db.localSettings)..where((t) => t.key.equals(key))).go();

  /// Удалить настройки пользователя (`scope=user`).
  Future<void> clearUserScope() =>
      (_db.delete(_db.localSettings)..where((t) => t.scope.equals(SettingScope.user.value))).go();
}
