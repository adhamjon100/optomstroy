// Порты core/sync (RM-E-009; 06 §6.12): core не импортирует фичи (FL-04), поэтому сеть каталога и статус
// обмена с 1С подключаются через интерфейсы ниже. Реализации — адаптеры фичи catalog
// (`features/catalog/data/local/*_adapter.dart`) поверх `CatalogSyncRepository` / `SyncStatusRepository`;
// подключение — `catalogOfflineFirstBindings` в композиционном корне `app/di/overrides.dart`.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';

/// Загрузка офлайн-кэша каталога: `GET /catalog/sync/{entity}` с курсором `since` (08 §4.24; 07 §11.4).
abstract interface class CatalogCachePort {
  /// Сущность до `hasMore=false`, начиная с сохранённого курсора (`sync_meta.server_cursor`).
  /// Каждая страница применяется к drift атомарно вместе с курсором — обрыв продолжается с курсора.
  /// [restart] — загрузка без `since` (повторная полная, «полная замена» по завершении).
  Future<Result<CacheEntityProgress>> syncEntity(
    String entity, {
    bool restart = false,
    int limit = 200,
    void Function(CacheEntityProgress progress)? onPage,
  });

  /// `app_meta.catalog_full_loaded_at` (`null` — первичная загрузка не завершена).
  Future<Result<DateTime?>> fullLoadedAt();

  /// Отметить завершение первичной загрузки.
  Future<Result<void>> markFullLoaded(DateTime at);
}

/// Статус обмена с 1С и ручной запуск (08 §4.17; SCR-43, `SyncIndicator`).
abstract interface class SyncStatusPort {
  /// `GET /sync/status`; адаптер попутно сохраняет пороги устаревания в `sync_meta.stale_after_sec`.
  Future<Result<SyncServerStatus>> status();

  /// `GET /sync/runs` (`sync.runs.read`).
  Future<Result<SyncRunsPage>> runs({SyncEntity? entity, int limit = 50, String? cursor});

  /// `GET /sync/runs/{id}`.
  Future<Result<SyncRunInfo>> run(String runId);

  /// `POST /sync/runs {entity, mode}` + `Idempotency-Key` (+ `X-Step-Up-Token` для `sync.run.full`) → `202`.
  Future<Result<SyncRunInfo>> startRun({
    required SyncEntity entity,
    required SyncMode mode,
    required String idempotencyKey,
    String? stepUpToken,
  });
}

/// Кэш, который обновляется после восстановления сети (`SyncScheduler.refreshStale()`, 06 §6.12).
abstract interface class RefreshableCache {
  /// Обновить устаревшие данные (без ошибок наружу; итог — в состоянии кэша).
  Future<void> refreshStale();
}
