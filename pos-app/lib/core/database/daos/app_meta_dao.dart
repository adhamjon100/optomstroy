// `app_meta` — служебные ключи локальной БД (07 §11.2, §11.5).
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/tables/local_tables.dart';

part 'app_meta_dao.g.dart';

@DriftAccessor(tables: [AppMeta])
class AppMetaDao extends DatabaseAccessor<AppDatabase> with _$AppMetaDaoMixin {
  AppMetaDao(super.attachedDatabase);

  /// Известные ключи (07 §11.2).
  static const String schemaVersionKey = 'schema_version';
  static const String catalogFullLoadedAtKey = 'catalog_full_loaded_at';
  static const String minAppVersionSeenKey = 'min_app_version_seen';
  static const String recommendedAppVersionSeenKey = 'recommended_app_version_seen';
  static const String userIdKey = 'user_id';

  /// Момент последнего обслуживания кэша (удаление строк с `deletion_mark`, VACUUM — 07 §11.4 «Еженедельно»).
  /// Ключа нет в перечне 07 §11.2 — EQ (E_spec_questions, раздел FIX).
  static const String catalogMaintenanceAtKey = 'catalog_maintenance_at';

  /// Область видимости остатков, с которой загружен кэш `stock` (`customer:status|customer:quantity`): при её смене
  /// сущность перезагружается без `since` (DATA-262; ядро v1.9 §24.2). Ключа нет в 07 §11.2 — EQ (раздел FIX).
  static const String catalogStockScopeKey = 'catalog_stock_scope';

  Future<String?> read(String key) async =>
      (await (select(appMeta)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> write(String key, String value) =>
      into(appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(key: key, value: value));

  Future<void> remove(String key) => (delete(appMeta)..where((t) => t.key.equals(key))).go();
}
