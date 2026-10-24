// Модели core/sync (RM-E-009): загрузка офлайн-кэша каталога, свежесть данных, индикатор синхронизации,
// краткий статус обмена с 1С для SCR-43. Чистый Dart, без фреймворков: core не знает о фичах (FL-04),
// поэтому порты core/sync описаны собственными типами, а фича catalog реализует их адаптерами
// (features/catalog/data/local/**).
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';

/// Итог загрузки одной сущности кэша (`GET /catalog/sync/{entity}` до `hasMore=false` или одна страница).
final class CacheEntityProgress {
  const CacheEntityProgress({
    required this.entity,
    required this.pages,
    required this.rows,
    required this.deleted,
    required this.completed,
    this.fullReload = false,
  });

  /// Значение `sync_meta.entity` (`units`, `products`, …; 07 §11.2).
  final String entity;
  final int pages;

  /// Строк применено (upsert).
  final int rows;

  /// Идентификаторов `deleted[]` обработано.
  final int deleted;

  /// `hasMore=false` достигнут.
  final bool completed;

  /// Загрузка шла без `since` (первичная или после `cursor_expired`).
  final bool fullReload;
}

/// Фаза загрузки кэша каталога.
enum CatalogLoadPhase {
  /// Ещё не запускалась (или БД пользователя не открыта).
  idle,

  /// Идёт первичная загрузка (NFR-PERF-006, индикатор «Загружаем каталог… N %»).
  initialLoading,

  /// Идёт инкремент (`since=<cursor>`).
  refreshing,

  /// Кэш загружен.
  ready,

  /// Последняя попытка завершилась ошибкой (курсор сохранён — следующая попытка продолжит).
  failed,
}

/// Состояние загрузки кэша каталога (для индикатора первичной загрузки и `SyncIndicator`).
final class CatalogLoadState {
  const CatalogLoadState({
    this.phase = CatalogLoadPhase.idle,
    this.entity,
    this.completedEntities = const <String>{},
    this.totalEntities = 0,
    this.pages = 0,
    this.rows = 0,
    this.entityPages = 0,
    this.fullyLoaded = false,
    this.failure,
    this.startedAt,
    this.finishedAt,
  });

  final CatalogLoadPhase phase;

  /// Сущность, которая загружается сейчас.
  final String? entity;

  /// Сущности, завершённые в текущем проходе (или ранее — при продолжении первичной загрузки).
  final Set<String> completedEntities;
  final int totalEntities;

  /// Страниц и строк за текущий проход.
  final int pages;
  final int rows;

  /// Страниц текущей сущности.
  final int entityPages;

  /// `app_meta.catalog_full_loaded_at` задан.
  final bool fullyLoaded;
  final Failure? failure;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// Каталог можно показывать (07 §11.4: «UI доступен после categories + products»).
  bool get uiReady =>
      fullyLoaded || (completedEntities.contains('categories') && completedEntities.contains('products'));

  bool get isRunning => phase == CatalogLoadPhase.initialLoading || phase == CatalogLoadPhase.refreshing;

  /// Длительность последнего прохода.
  Duration? get elapsed => startedAt == null || finishedAt == null ? null : finishedAt!.difference(startedAt!);

  /// Оценка прогресса первичной загрузки 0…100 (веса сущностей по объёму; внутри сущности — по страницам).
  int get percent {
    if (fullyLoaded) return 100;
    if (totalEntities == 0) return 0;
    var done = 0.0;
    var total = 0.0;
    for (final e in loadWeights.entries) {
      total += e.value;
      if (completedEntities.contains(e.key)) done += e.value;
    }
    final current = entity;
    if (current != null && !completedEntities.contains(current)) {
      final w = loadWeights[current] ?? 1;
      // Число страниц сущности заранее неизвестно — доля насыщается и не доходит до 100 %.
      done += w * (entityPages / (entityPages + 10));
    }
    if (total == 0) return 0;
    final p = (done * 100 / total).floor();
    return p.clamp(0, phase == CatalogLoadPhase.ready ? 100 : 99);
  }

  /// Относительный объём сущностей (оценка для процента: товары, варианты, цены — основная масса).
  static const Map<String, double /* money-double: allow — доля прогресса */> loadWeights = <String, double>{
    'units': 1,
    'categories': 2,
    'warehouses': 1,
    'price_lists': 1,
    'products': 25,
    'variants': 20,
    'packagings': 5,
    'barcodes': 10,
    'prices': 15,
    'stock': 12,
    'images': 8,
  };

  CatalogLoadState copyWith({
    CatalogLoadPhase? phase,
    String? entity,
    bool clearEntity = false,
    Set<String>? completedEntities,
    int? totalEntities,
    int? pages,
    int? rows,
    int? entityPages,
    bool? fullyLoaded,
    Failure? failure,
    bool clearFailure = false,
    DateTime? startedAt,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
  }) => CatalogLoadState(
    phase: phase ?? this.phase,
    entity: clearEntity ? null : (entity ?? this.entity),
    completedEntities: completedEntities ?? this.completedEntities,
    totalEntities: totalEntities ?? this.totalEntities,
    pages: pages ?? this.pages,
    rows: rows ?? this.rows,
    entityPages: entityPages ?? this.entityPages,
    fullyLoaded: fullyLoaded ?? this.fullyLoaded,
    failure: clearFailure ? null : (failure ?? this.failure),
    startedAt: startedAt ?? this.startedAt,
    finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
  );

  @override
  String toString() =>
      'CatalogLoadState(${phase.name}, entity: $entity, done: ${completedEntities.length}/$totalEntities)';
}

/// Метка синхронизации сущности на устройстве (`sync_meta`, 07 §11.2) — без типов drift для presentation.
final class LocalEntitySync {
  const LocalEntitySync({
    required this.entity,
    this.asOf,
    this.lastSuccessAt,
    this.lastError,
    this.staleAfter,
    this.hasCursor = false,
  });

  final String entity;

  /// Момент данных сервера (`serverTime` последней страницы).
  final DateTime? asOf;
  final DateTime? lastSuccessAt;

  /// Машинный код последней ошибки (без ПДн).
  final String? lastError;

  /// Порог устаревания (`sync_meta.stale_after_sec`); `null` — порог по умолчанию [DataFreshness.defaultStaleAfter].
  final Duration? staleAfter;
  final bool hasCursor;

  /// Данные старше порога (DATA-256).
  bool isStale(DateTime now) => asOf == null || now.difference(asOf!) > (staleAfter ?? DataFreshness.defaultStaleAfter);
}

/// «Офлайн/онлайн + возраст данных» для экранов каталога (OfflineBanner, метка «данные от HH:MM»).
final class DataFreshness {
  const DataFreshness({
    required this.online,
    required this.now,
    this.asOf,
    this.lastSuccessAt,
    this.stale = false,
    this.fullyLoaded = false,
    this.load = const CatalogLoadState(),
    this.lastError,
  });

  /// Порог устаревания, пока `GET /sync/status` не сообщил свой (`2 × intervalSec`, 07 §11.2, DATA-256).
  /// [EQ-E009-02]: до первого ответа статуса — 15 мин (AC-DATA-256: офлайн 20 мин → баннер возраста).
  static const Duration defaultStaleAfter = Duration(minutes: 15);

  /// Сущности, по которым считается возраст каталога для UI (самая старая метка).
  static const Set<String> ageEntities = <String>{'products', 'prices', 'stock'};

  final OnlineStatus online;
  final DateTime now;

  /// Самая старая метка данных среди [ageEntities] (`null` — кэша нет).
  final DateTime? asOf;
  final DateTime? lastSuccessAt;

  /// Цены или остатки старше порога.
  final bool stale;

  /// Первичная загрузка завершена.
  final bool fullyLoaded;
  final CatalogLoadState load;

  /// Код последней ошибки загрузки кэша.
  final String? lastError;

  /// Нет связи с backend (OfflineBanner `offline`).
  bool get isOffline => online == OnlineStatus.offline;

  /// Соединение есть, сервер не отвечает (OfflineBanner `serverDown`).
  bool get isServerDown => online == OnlineStatus.serverDown;

  /// Данные берутся из кэша устройства (офлайн или сервер недоступен).
  bool get fromCache => isOffline || isServerDown;

  /// Есть данные кэша.
  bool get hasCache => asOf != null;

  /// Возраст данных.
  Duration? get age => asOf == null ? null : now.difference(asOf!);
}

/// Варианты `SyncIndicator` (03 §9.40).
enum SyncIndicatorStatus {
  /// `sync` `textSecondary`, «обновлено 09:41».
  ok,

  /// Вращение (ANIM-021), «обновляем…».
  syncing,

  /// `warning`, «данные от 08:10».
  stale,

  /// `sync_problem` `error`.
  error,

  /// `cloud_off` `warning`, «нет сети».
  offline,

  /// Ещё не синхронизировано (первый запуск).
  never,
}

/// Состояние `SyncIndicator` в шапке: вариант и время для подписи.
final class SyncIndicatorInfo {
  const SyncIndicatorInfo({required this.status, this.time});

  /// Вывод из свежести кэша (сеть, загрузка, порог, ошибка).
  factory SyncIndicatorInfo.from(DataFreshness f) {
    if (f.isOffline) return SyncIndicatorInfo(status: SyncIndicatorStatus.offline, time: f.asOf);
    if (f.load.isRunning) return SyncIndicatorInfo(status: SyncIndicatorStatus.syncing, time: f.asOf);
    if (f.asOf == null) {
      return SyncIndicatorInfo(
        status: f.load.phase == CatalogLoadPhase.failed ? SyncIndicatorStatus.error : SyncIndicatorStatus.never,
      );
    }
    if (f.load.phase == CatalogLoadPhase.failed || f.lastError != null) {
      return SyncIndicatorInfo(status: SyncIndicatorStatus.error, time: f.asOf);
    }
    if (f.stale) return SyncIndicatorInfo(status: SyncIndicatorStatus.stale, time: f.asOf);
    return SyncIndicatorInfo(status: SyncIndicatorStatus.ok, time: f.lastSuccessAt ?? f.asOf);
  }

  final SyncIndicatorStatus status;
  final DateTime? time;

  @override
  bool operator ==(Object other) => other is SyncIndicatorInfo && other.status == status && other.time == time;

  @override
  int get hashCode => Object.hash(status, time);
}

// ---------------------------------------------------------------------------
// Статус обмена с 1С (`GET /sync/status`, `/sync/runs`; 08 §4.17) — для SCR-43 через порт SyncStatusPort.
// ---------------------------------------------------------------------------

/// Состояние сущности обмена (`SyncEntityStatus`).
final class SyncServerEntity {
  const SyncServerEntity({
    required this.entityValue,
    this.lastSuccessAt,
    this.lastRunAt,
    this.running = false,
    this.runId,
    this.consecutiveErrors = 0,
    this.nextRunAt,
    this.intervalSec,
    this.ageSec,
    this.isStale = false,
    this.paused = false,
    this.fetched,
    this.sourceTotal,
  });

  /// Исходная строка (совместимость вперёд); типизированно — [entity].
  final String entityValue;
  final DateTime? lastSuccessAt;
  final DateTime? lastRunAt;
  final bool running;
  final String? runId;
  final int consecutiveErrors;
  final DateTime? nextRunAt;
  final int? intervalSec;
  final int? ageSec;
  final bool isStale;
  final bool paused;

  /// Счётчики текущего/последнего прогона (`sync.runs.read`).
  final int? fetched;
  final int? sourceTotal;

  SyncEntity? get entity => SyncEntity.tryParse(entityValue);

  /// Доля прогресса прогона 0…1 (`fetched/sourceTotal`) или `null`.
  double /* money-double: allow — доля прогресса */ ? get progress {
    final f = fetched;
    final t = sourceTotal;
    if (f == null || t == null || t <= 0) return null;
    return (f / t).clamp(0.0, 1.0);
  }
}

/// Счётчики очереди обмена с 1С (`SyncStatus.outbox`).
final class SyncServerOutbox {
  const SyncServerOutbox({this.pending = 0, this.failed = 0, this.dead = 0});

  final int pending;
  final int failed;
  final int dead;
}

/// `GET /sync/status` (`SyncStatus`).
final class SyncServerStatus {
  const SyncServerStatus({
    required this.onecReachable,
    required this.checkedAt,
    required this.overall,
    this.entities = const <SyncServerEntity>[],
    this.outbox,
  });

  final bool onecReachable;
  final DateTime checkedAt;

  /// `ok` | `degraded` | `failed`.
  final String overall;
  final List<SyncServerEntity> entities;

  /// Полный ответ (`sync.runs.read`); краткий — `null`.
  final SyncServerOutbox? outbox;

  SyncServerEntity? entity(SyncEntity e) {
    for (final x in entities) {
      if (x.entity == e) return x;
    }
    return null;
  }

  /// Ни одной успешной синхронизации (SCR-43 состояние `never`).
  bool get never => entities.isNotEmpty && entities.every((e) => e.lastSuccessAt == null);

  /// Последний успешный обмен по всем сущностям.
  DateTime? get lastSuccessAt {
    DateTime? best;
    for (final e in entities) {
      final t = e.lastSuccessAt;
      if (t != null && (best == null || t.isAfter(best))) best = t;
    }
    return best;
  }
}

/// Прогон синхронизации (`SyncRun`).
final class SyncRunInfo {
  const SyncRunInfo({
    required this.id,
    required this.entityValue,
    required this.modeValue,
    required this.statusValue,
    this.triggerValue,
    this.startedAt,
    this.finishedAt,
    this.triggeredByName,
    this.fetched,
    this.sourceTotal,
    this.errors,
  });

  final String id;
  final String entityValue;
  final String modeValue;
  final String statusValue;
  final String? triggerValue;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? triggeredByName;
  final int? fetched;
  final int? sourceTotal;
  final int? errors;

  SyncEntity? get entity => SyncEntity.tryParse(entityValue);
  SyncMode? get mode => SyncMode.tryParse(modeValue);
  SyncRunStatus? get status => SyncRunStatus.tryParse(statusValue);
  SyncTrigger? get trigger => triggerValue == null ? null : SyncTrigger.tryParse(triggerValue);

  /// Прогон завершён (`success` | `partial` | `failed`).
  bool get finished =>
      status == SyncRunStatus.success || status == SyncRunStatus.partial || status == SyncRunStatus.failed;
}

/// Страница прогонов.
final class SyncRunsPage {
  const SyncRunsPage({required this.items, this.nextCursor, this.hasMore = false});

  final List<SyncRunInfo> items;
  final String? nextCursor;
  final bool hasMore;
}
