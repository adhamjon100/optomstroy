// Загрузка офлайн-кэша каталога (RM-E-009; 07 §11.4; 08 §4.24; ядро §22.7; NFR-PERF-006, DATA-257).
//
// Первичная загрузка (`app_meta.catalog_full_loaded_at` пуст): сущности в порядке 07 §11.4
// `units → categories → warehouses → price_lists → products → variants → packagings → barcodes → prices →
// stock → images`, страницами по 200; каждая страница применяется к drift в одной транзакции с курсором,
// поэтому обрыв (сеть, закрытие приложения) продолжается с `sync_meta.server_cursor` без дублей.
// Сущности, завершённые в прерванной загрузке (`sync_meta.last_success_at` задан), при продолжении
// пропускаются — их догоняет инкремент после завершения первичной загрузки.
// UI каталога доступен после `categories + products` (`CatalogLoadState.uiReady`).
//
// Инкремент (`refreshStale`): после восстановления сети и по расписанию — сущности, у которых сервер
// обновлялся позже локальной метки (`GET /sync/status`, 07 §11.4 «Старт приложения онлайн»), а без статуса —
// сущности старше порога `sync_meta.stale_after_sec`.
//
// SQLite пользователя открыт через `drift_flutter` в фоновом изоляте (D-04): вставка страниц не блокирует UI;
// на главном изоляте — только разбор JSON страницы (≤ 200 строк).
//
// Прогон привязан к экземпляру БД пользователя, открытому на его старте (07 §11.1 п.2: данные разных
// пользователей не смешиваются): если БД сменилась (выход, вход другого сотрудника), прогон прерывается на
// границе сущности, `catalog_full_loaded_at` не пишется, а вызов для новой БД получает свой прогон, а не чужой.
import 'dart:async';

import 'package:optomstroy/core/database/daos/app_meta_dao.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/utils/clock.dart';

/// Причина `UnknownFailure`, когда порт кэша не подключён или БД пользователя не открыта.
final class CatalogCacheNotReady {
  const CatalogCacheNotReady();

  @override
  String toString() => 'CatalogCacheNotReady';
}

final class CatalogSyncEngine implements RefreshableCache {
  CatalogSyncEngine({
    required CatalogCachePort? Function() port,
    required CatalogDao? Function() dao,
    required Clock clock,
    SyncStatusPort? Function()? status,
    List<String> order = catalogSyncLoadOrder,
    int pageSize = 200,
  }) : _port = port,
       _dao = dao,
       _clock = clock,
       _status = status,
       _order = order,
       _pageSize = pageSize;

  final CatalogCachePort? Function() _port;
  final CatalogDao? Function() _dao;
  final Clock _clock;
  final SyncStatusPort? Function()? _status;
  final List<String> _order;
  final int _pageSize;

  final StreamController<CatalogLoadState> _states = StreamController<CatalogLoadState>.broadcast();
  CatalogLoadState _state = const CatalogLoadState();
  Future<CatalogLoadState>? _inflight;
  CatalogDao? _inflightDao;

  /// Текущее состояние.
  CatalogLoadState get state => _state;

  /// Изменения состояния (страница за страницей — для индикатора NFR-PERF-006).
  Stream<CatalogLoadState> get states => _states.stream;

  /// Сущности серверного статуса → сущности кэша (packagings/price_lists грузятся с products/prices — T-SYNC-001).
  static const Map<String, List<String>> serverToCache = <String, List<String>>{
    'units': ['units'],
    'categories': ['categories'],
    'warehouses': ['warehouses'],
    'products': ['products', 'packagings'],
    'variants': ['variants'],
    'barcodes': ['barcodes'],
    'prices': ['price_lists', 'prices'],
    'stock': ['stock'],
    'images': ['images'],
  };

  void _emit(CatalogLoadState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Первичная загрузка, если она не завершена (продолжение с курсоров); иначе — без запросов.
  Future<CatalogLoadState> ensureLoaded() => _single(_ensureLoaded);

  /// Старт приложения онлайн / вход пользователя (07 §11.4 «Старт приложения онлайн»): незавершённая первичная
  /// загрузка — продолжить; иначе — `GET /sync/status` и инкремент `?since=` сущностей, обновлённых на сервере
  /// позже локальной метки `as_of` (без статуса — старше порога устаревания).
  Future<CatalogLoadState> start() => _single(() async {
    final loaded = await _fullyLoaded();
    if (loaded != true) return _ensureLoaded();
    final ready = await _ensureLoaded();
    if (ready.phase != CatalogLoadPhase.ready) return ready;
    return _refresh(await _staleEntities());
  });

  /// Область видимости остатков сменилась (клиент: `customer_stock_display` `status` ↔ `quantity`, DATA-262):
  /// курсор сервера область не кодирует, а неизменённые строки инкремент не присылает — `stock` перезагружается без
  /// `since` («полная замена»: под `status` количества в `stock_balances` становятся NULL). Первая запись области —
  /// без перезагрузки. `true` — перезагрузка выполнена.
  Future<bool> applyStockScope(String scope) async {
    final running = _inflight;
    if (running != null) {
      try {
        await running;
      } on Object {
        // Итог идущего прогона — в его состоянии.
      }
    }
    final dao = _dao();
    if (dao == null) return false;
    final meta = dao.attachedDatabase.appMetaDao;
    final stored = await meta.read(AppMetaDao.catalogStockScopeKey);
    if (stored == scope) return false;
    await meta.write(AppMetaDao.catalogStockScopeKey, scope);
    if (stored == null) return false;
    await dao.resetSyncCursor('stock');
    await refresh(entities: const <String>{'stock'});
    return true;
  }

  /// Еженедельное обслуживание кэша (07 §11.4): удаление строк с `deletion_mark` старше сроков 07 §11.2 и
  /// `VACUUM`. Не во время загрузки; ошибки поглощаются (кэш остаётся рабочим). `true` — выполнено.
  Future<bool> maintain() async {
    final dao = _dao();
    if (dao == null || _inflight != null) return false;
    try {
      return await dao.runMaintenance(nowMs: _clock.nowUtc().millisecondsSinceEpoch);
    } on Object {
      return false;
    }
  }

  /// Выход / смена пользователя: состояние прежней БД больше не показывается (прогон, если он идёт,
  /// прервётся на границе сущности — БД уже другая).
  void reset() => _emit(const CatalogLoadState());

  /// Инкремент указанных сущностей (по умолчанию — всех) от сохранённых курсоров.
  Future<CatalogLoadState> refresh({Set<String>? entities}) => _single(() => _refresh(entities));

  /// Обновить устаревшее (06 §6.12): незавершённую первичную загрузку — продолжить, иначе — инкремент.
  @override
  Future<void> refreshStale() async {
    await _single(() async {
      final loaded = await _fullyLoaded();
      if (loaded == null) return _state;
      if (!loaded) return _ensureLoaded();
      return _refresh(await _staleEntities());
    });
  }

  /// Один прогон на БД пользователя. Идущий прогон другой БД (пользователь сменился) не возвращается
  /// вызывающему: новый прогон начинается после его прерывания.
  Future<CatalogLoadState> _single(Future<CatalogLoadState> Function() run) {
    final dao = _dao();
    final current = _inflight;
    if (current != null && identical(_inflightDao, dao)) return current;
    final Future<void> previous = current == null ? Future<void>.value() : current.then<void>((_) {}, onError: (_) {});
    late final Future<CatalogLoadState> next;
    next = previous.then((_) => run()).whenComplete(() {
      if (identical(_inflight, next)) {
        _inflight = null;
        _inflightDao = null;
      }
    });
    _inflight = next;
    _inflightDao = dao;
    return next;
  }

  /// БД пользователя сменилась после начала прогона над [dao].
  bool _switched(CatalogDao dao) => !identical(_dao(), dao);

  /// Прогон прежней БД прерван: его состояние не переносится на новую.
  CatalogLoadState _abandon() {
    const s = CatalogLoadState();
    _emit(s);
    return s;
  }

  /// `null` — порт/БД не готовы.
  Future<bool?> _fullyLoaded() async {
    final port = _port();
    if (port == null || _dao() == null) return null;
    final r = await port.fullLoadedAt();
    return r.valueOrNull != null;
  }

  CatalogLoadState _notReady() {
    final s = _state.copyWith(
      phase: CatalogLoadPhase.failed,
      failure: const UnknownFailure(cause: CatalogCacheNotReady()),
    );
    _emit(s);
    return s;
  }

  Future<CatalogLoadState> _ensureLoaded() async {
    final port = _port();
    final dao = _dao();
    if (port == null || dao == null) return _notReady();
    final loadedAt = (await port.fullLoadedAt()).valueOrNull;
    if (loadedAt != null) {
      final s = _state.copyWith(
        phase: CatalogLoadPhase.ready,
        fullyLoaded: true,
        completedEntities: _order.toSet(),
        totalEntities: _order.length,
        clearEntity: true,
        clearFailure: true,
      );
      _emit(s);
      return s;
    }
    final meta = {for (final m in await dao.allSyncMeta()) m.entity: m};
    final done = <String>{
      for (final e in _order)
        if (meta[e]?.lastSuccessAt != null) e,
    };
    final started = _clock.nowUtc();
    _emit(
      CatalogLoadState(
        phase: CatalogLoadPhase.initialLoading,
        completedEntities: done,
        totalEntities: _order.length,
        startedAt: started,
      ),
    );
    for (final entity in _order) {
      if (done.contains(entity)) continue;
      if (_switched(dao)) return _abandon();
      final failure = await _syncOne(port, entity, initial: true);
      if (_switched(dao)) return _abandon();
      if (failure != null) return _fail(failure);
    }
    final finished = _clock.nowUtc();
    // Проверка и запись метки — в одном синхронном участке: порт читает `app_meta` текущей БД до первого await.
    if (_switched(dao)) return _abandon();
    await port.markFullLoaded(finished);
    final s = _state.copyWith(
      phase: CatalogLoadPhase.ready,
      fullyLoaded: true,
      clearEntity: true,
      finishedAt: finished,
      clearFailure: true,
    );
    _emit(s);
    return s;
  }

  Future<CatalogLoadState> _refresh(Set<String>? entities) async {
    final port = _port();
    final dao = _dao();
    if (port == null || dao == null) return _notReady();
    final targets = [
      for (final e in _order)
        if (entities == null || entities.contains(e)) e,
    ];
    final fully = (await port.fullLoadedAt()).valueOrNull != null;
    if (targets.isEmpty) {
      final s = _state.copyWith(phase: fully ? CatalogLoadPhase.ready : _state.phase, fullyLoaded: fully);
      _emit(s);
      return s;
    }
    _emit(
      _state.copyWith(
        phase: CatalogLoadPhase.refreshing,
        fullyLoaded: fully,
        pages: 0,
        rows: 0,
        totalEntities: _order.length,
        startedAt: _clock.nowUtc(),
        clearFinishedAt: true,
        clearFailure: true,
      ),
    );
    Failure? firstFailure;
    for (final entity in targets) {
      if (_switched(dao)) return _abandon();
      final failure = await _syncOne(port, entity, initial: false);
      if (_switched(dao)) return _abandon();
      if (failure is NetworkFailure) return _fail(failure); // связи нет — остальные сущности тоже не загрузятся
      firstFailure ??= failure;
    }
    if (firstFailure != null) return _fail(firstFailure);
    final s = _state.copyWith(
      phase: fully ? CatalogLoadPhase.ready : CatalogLoadPhase.idle,
      clearEntity: true,
      finishedAt: _clock.nowUtc(),
    );
    _emit(s);
    return s;
  }

  CatalogLoadState _fail(Failure failure) {
    final s = _state.copyWith(phase: CatalogLoadPhase.failed, failure: failure, finishedAt: _clock.nowUtc());
    _emit(s);
    return s;
  }

  /// Загрузить сущность до конца; `null` — успех.
  Future<Failure?> _syncOne(CatalogCachePort port, String entity, {required bool initial}) async {
    final base = _state;
    _emit(base.copyWith(entity: entity, entityPages: 0));
    final r = await port.syncEntity(
      entity,
      limit: _pageSize,
      onPage: (p) => _emit(
        _state.copyWith(entity: entity, entityPages: p.pages, pages: base.pages + p.pages, rows: base.rows + p.rows),
      ),
    );
    switch (r) {
      case Success(:final value):
        _emit(
          _state.copyWith(
            completedEntities: {..._state.completedEntities, entity},
            pages: base.pages + value.pages,
            rows: base.rows + value.rows,
          ),
        );
        return null;
      case FailureResult(:final failure):
        return failure;
    }
  }

  /// Сущности для инкремента: по серверному статусу (сервер обновлялся позже `as_of`), иначе — по порогу.
  Future<Set<String>> _staleEntities() async {
    final dao = _dao();
    if (dao == null) return const <String>{};
    final now = _clock.nowUtc();
    final local = {for (final m in await dao.allSyncMeta()) m.entity: m};
    DateTime? asOf(String e) {
      final v = local[e]?.asOf;
      return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    }

    final statusPort = _status?.call();
    if (statusPort != null) {
      final r = await statusPort.status();
      final status = r.valueOrNull;
      if (status != null) {
        final out = <String>{};
        for (final e in status.entities) {
          final targets = serverToCache[e.entityValue];
          final server = e.lastSuccessAt;
          if (targets == null || server == null) continue;
          for (final t in targets) {
            final mine = asOf(t);
            if (mine == null || server.isAfter(mine)) out.add(t);
          }
        }
        return out;
      }
    }
    return {
      for (final e in _order)
        if (_isStale(asOf(e), local[e]?.staleAfterSec, now)) e,
    };
  }

  static bool _isStale(DateTime? asOf, int? staleAfterSec, DateTime now) {
    if (asOf == null) return true;
    final limit = staleAfterSec == null ? DataFreshness.defaultStaleAfter : Duration(seconds: staleAfterSec);
    return now.difference(asOf) > limit;
  }

  Future<void> dispose() => _states.close();
}
