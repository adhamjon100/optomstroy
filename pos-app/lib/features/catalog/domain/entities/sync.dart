// Синхронизация: офлайн-кэш каталога (`GET /catalog/sync/{entity}`, 08 §4.24, ядро §22.7) и статус
// обмена с 1С (`GET /sync/status`, `/sync/runs`, 08 §4.17; SCR-43, `SyncIndicator`). Чистый Dart.
import 'package:optomstroy/core/enums.dart';

/// Сущность выгрузки `GET /catalog/sync/{entity}` (`CatalogSyncEntity`, ровно перечень ядра §22.7).
enum CatalogSyncEntity {
  units('units'),
  categories('categories'),
  attributes('attributes'),
  warehouses('warehouses'),
  priceLists('price_lists'),
  products('products'),
  variants('variants'),
  packagings('packagings'),
  barcodes('barcodes'),
  prices('prices'),
  stock('stock'),
  images('images');

  const CatalogSyncEntity(this.value);

  /// Значение path-параметра (и `sync_meta.entity` локальной БД).
  final String value;

  /// Порядок первичной загрузки кэша (07 §11.4): `attributes` в кэш не загружаются —
  /// отдельной локальной таблицы нет, свойства хранятся в карточке товара.
  static const List<CatalogSyncEntity> cacheLoadOrder = <CatalogSyncEntity>[
    units,
    categories,
    warehouses,
    priceLists,
    products,
    variants,
    packagings,
    barcodes,
    prices,
    stock,
    images,
  ];

  /// После каких сущностей каталог доступен в UI (07 §11.4: «UI доступен после categories + products»).
  static const Set<CatalogSyncEntity> uiReadyAfter = <CatalogSyncEntity>{categories, products};

  bool get cached => this != attributes;

  static CatalogSyncEntity? tryParse(String? value) {
    for (final e in values) {
      if (e.value == value) return e;
    }
    return null;
  }
}

/// Локальная метка синхронизации сущности (`sync_meta`, 07 §11.2).
final class LocalSyncState {
  const LocalSyncState({
    required this.entity,
    this.lastSuccessAt,
    this.cursor,
    this.lastError,
    this.asOf,
    this.staleAfter,
  });

  final CatalogSyncEntity entity;
  final DateTime? lastSuccessAt;

  /// Непрозрачный курсор `since` (`nextCursor` последней применённой страницы).
  final String? cursor;
  final String? lastError;

  /// Момент данных сервера (`serverTime` / `X-Data-As-Of`).
  final DateTime? asOf;

  /// Порог устаревания (`maxAgeWarningSec` или `2 × intervalSec`).
  final Duration? staleAfter;

  /// Данные старше порога (офлайн-признак устаревания, DATA-256).
  bool isStale(DateTime now) => asOf == null || (staleAfter != null && now.difference(asOf!) > staleAfter!);
}

/// Итог загрузки сущности в кэш.
final class CatalogSyncProgress {
  const CatalogSyncProgress({
    required this.entity,
    required this.pages,
    required this.upserted,
    required this.deleted,
    required this.completed,
    this.cursor,
    this.serverTime,
    this.fullReload = false,
  });

  final CatalogSyncEntity entity;
  final int pages;
  final int upserted;
  final int deleted;

  /// `hasMore=false` достигнут.
  final bool completed;
  final String? cursor;
  final DateTime? serverTime;

  /// Загрузка шла без `since` (первичная или после `cursor_expired`).
  final bool fullReload;
}

/// Общее состояние обмена (`SyncStatus.overall`).
enum SyncOverall {
  ok('ok'),
  degraded('degraded'),
  failed('failed');

  const SyncOverall(this.value);

  final String value;

  static SyncOverall parse(String? value) {
    for (final o in values) {
      if (o.value == value) return o;
    }
    return degraded;
  }
}

/// Счётчики прогона (`SyncCounts`).
final class SyncCounts {
  const SyncCounts({this.fetched, this.upserted, this.deleted, this.errors, this.sourceTotal});

  final int? fetched;
  final int? upserted;
  final int? deleted;
  final int? errors;
  final int? sourceTotal;
}

/// Состояние сущности обмена (`SyncEntityStatus`).
final class SyncEntityStatus {
  const SyncEntityStatus({
    required this.entity,
    this.entityValue,
    this.lastSuccessAt,
    this.lastRunAt,
    this.running = false,
    this.runId,
    this.consecutiveErrors = 0,
    this.lastErrorAt,
    this.paused = false,
    this.nextRunAt,
    this.intervalSec,
    this.ageSec,
    this.isStale = false,
    this.counts,
  });

  /// `null` — значение, неизвестное клиенту (совместимость вперёд; исходная строка — [entityValue]).
  final SyncEntity? entity;
  final String? entityValue;
  final DateTime? lastSuccessAt;
  final DateTime? lastRunAt;
  final bool running;
  final String? runId;

  /// Ошибок подряд (ядро §19.2).
  final int consecutiveErrors;
  final DateTime? lastErrorAt;
  final bool paused;
  final DateTime? nextRunAt;
  final int? intervalSec;
  final int? ageSec;
  final bool isStale;
  final SyncCounts? counts;

  /// Порог устаревания для офлайн-проверки: `2 × intervalSec` (07 §11.2, до поля `maxAgeWarningSec`).
  Duration? get staleAfter => intervalSec == null ? null : Duration(seconds: 2 * intervalSec!);
}

/// Состояние очереди обмена с 1С (`SyncStatus.outbox`).
final class SyncOutboxCounts {
  const SyncOutboxCounts({this.pending = 0, this.failed = 0, this.dead = 0});

  final int pending;
  final int failed;
  final int dead;
}

/// Заказы, ожидающие ручного оформления в 1С (`SyncStatus.pendingManualOrders`).
final class PendingManualOrders {
  const PendingManualOrders({this.count = 0, this.oldestAt, this.slaMin, this.overSla = false});

  final int count;
  final DateTime? oldestAt;
  final int? slaMin;
  final bool overSla;
}

/// `GET /sync/status` (`SyncStatus`): краткий ответ для всех staff, полный — по правам (SCR-43).
final class SyncStatusInfo {
  const SyncStatusInfo({
    required this.onecReachable,
    required this.checkedAt,
    required this.overall,
    this.entities = const <SyncEntityStatus>[],
    this.outbox,
    this.pendingManualOrders,
  });

  final bool onecReachable;
  final DateTime checkedAt;
  final SyncOverall overall;
  final List<SyncEntityStatus> entities;
  final SyncOutboxCounts? outbox;
  final PendingManualOrders? pendingManualOrders;

  SyncEntityStatus? entity(SyncEntity entity) {
    for (final e in entities) {
      if (e.entity == entity) return e;
    }
    return null;
  }
}

/// Прогон синхронизации (`SyncRun`).
final class SyncRun {
  const SyncRun({
    required this.id,
    required this.entityValue,
    required this.modeValue,
    required this.triggerValue,
    required this.statusValue,
    this.startedAt,
    this.finishedAt,
    this.triggeredById,
    this.triggeredByName,
    this.counts,
    this.errorSummary,
  });

  final String id;

  /// Исходные строки (совместимость вперёд); типизированные значения — геттеры.
  final String entityValue;
  final String modeValue;
  final String triggerValue;
  final String statusValue;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? triggeredById;

  /// Отображаемое имя запустившего (без телефона).
  final String? triggeredByName;
  final SyncCounts? counts;
  final String? errorSummary;

  SyncEntity? get entity => SyncEntity.tryParse(entityValue);
  SyncMode? get mode => SyncMode.tryParse(modeValue);
  SyncTrigger? get trigger => SyncTrigger.tryParse(triggerValue);
  SyncRunStatus? get status => SyncRunStatus.tryParse(statusValue);
}

/// Ошибка прогона (`SyncRunError`); `payload` не переносится в домен (может содержать данные 1С).
final class SyncRunError {
  const SyncRunError({
    required this.id,
    required this.entityValue,
    required this.errorCode,
    required this.message,
    this.onecRef,
    this.onecCode,
    this.resolvedAt,
  });

  final String id;
  final String entityValue;
  final String errorCode;
  final String message;
  final String? onecRef;
  final String? onecCode;
  final DateTime? resolvedAt;
}

/// Режим ручного запуска `POST /sync/runs` (`SyncRunsCreateRequest.mode`).
enum SyncRunRequestMode {
  incremental('incremental'),
  full('full'),
  reconcile('reconcile');

  const SyncRunRequestMode(this.value);

  final String value;
}
