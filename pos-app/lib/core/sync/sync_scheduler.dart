// Планировщик офлайн-синхронизации клиента (06 §6.12; D-32):
// - вход пользователя / старт приложения онлайн (БД открыта) → отправка outbox, затем первичная загрузка кэша
//   (продолжение с курсора) или, если кэш уже загружен, `GET /sync/status` и инкремент `?since=` (07 §11.4);
// - восстановление сети (`ConnectivityWatcher.networkRestored`) → `GET /health` → `OutboxQueue.flush()` →
//   `refreshStale()` всех кэшей (реестр `RefreshableCache`);
// - возврат backend из `offline`/`serverDown` в `online` (любой ответ сервера) → то же без проверки health;
// - действие поставлено в очередь при наличии сети → попытка отправки сразу;
// - периодически (по умолчанию 5 мин), пока сеть есть, — `refreshStale()` и повтор очереди по расписанию;
// - после входа и прохода — еженедельное обслуживание кэша (`deletion_mark` старше сроков, VACUUM; 07 §11.4).
// Ошибки наружу не выходят: итог — в состоянии кэша и очереди.
import 'dart:async';

import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/sync/catalog_sync_engine.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';

final class SyncScheduler {
  SyncScheduler({
    required OnlineStatus Function() onlineStatus,
    required Stream<OnlineStatus> statusChanges,
    required Stream<void> networkRestored,
    required OutboxQueue outbox,
    required CatalogSyncEngine catalog,
    List<RefreshableCache> caches = const <RefreshableCache>[],
    Future<bool> Function()? backendReachable,
    Duration? period = const Duration(minutes: 5),
  }) : _onlineStatus = onlineStatus,
       _statusChanges = statusChanges,
       _networkRestored = networkRestored,
       _outbox = outbox,
       _catalog = catalog,
       _caches = caches,
       _backendReachable = backendReachable,
       _period = period;

  final OnlineStatus Function() _onlineStatus;
  final Stream<OnlineStatus> _statusChanges;
  final Stream<void> _networkRestored;
  final OutboxQueue _outbox;
  final CatalogSyncEngine _catalog;
  final List<RefreshableCache> _caches;
  final Future<bool> Function()? _backendReachable;
  final Duration? _period;

  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  Timer? _timer;
  Future<void>? _cycle;
  bool _started = false;
  bool _signedIn = false;
  OnlineStatus _last = OnlineStatus.unknown;

  /// Нет связи с backend по последнему сигналу.
  bool get _offline => _onlineStatus() == OnlineStatus.offline;

  /// Подписаться на сигналы сети (повторный вызов — без эффекта).
  void start() {
    if (_started) return;
    _started = true;
    _last = _onlineStatus();
    _subs
      ..add(_networkRestored.listen((_) => unawaited(onNetworkRestored())))
      ..add(_statusChanges.listen(_onStatus));
    final period = _period;
    if (period != null) {
      _timer = Timer.periodic(period, (_) {
        if (_signedIn && !_offline) unawaited(_runCycle(checkHealth: false));
      });
    }
  }

  void _onStatus(OnlineStatus next) {
    final wasDown = _last == OnlineStatus.offline || _last == OnlineStatus.serverDown;
    _last = next;
    if (wasDown && next == OnlineStatus.online) unawaited(_runCycle(checkHealth: false));
  }

  /// БД пользователя открыта: отправка очереди и первичная загрузка (продолжение) либо инкремент
  /// по `GET /sync/status` (07 §11.4 «Старт приложения онлайн»).
  Future<void> onSignedIn() async {
    _signedIn = true;
    if (_offline) return;
    await _guard(() async {
      await _outbox.flush();
      await _catalog.start();
      await _catalog.maintain();
    });
  }

  /// Выход / смена пользователя: состояние загрузки прежнего пользователя сбрасывается.
  void onSignedOut() {
    _signedIn = false;
    _catalog.reset();
  }

  /// Сетевой интерфейс появился: проверить backend, отправить очередь, обновить устаревшее.
  Future<void> onNetworkRestored() => _runCycle(checkHealth: true);

  /// Действие поставлено в очередь: отправить сразу, если сеть есть (иначе — после восстановления).
  void onEnqueued() {
    if (_offline) return;
    unawaited(_guard(_outbox.flush));
  }

  Future<void> _runCycle({required bool checkHealth}) => _cycle ??= _guard(() async {
    if (!_signedIn) return;
    if (checkHealth && _backendReachable != null && !await _backendReachable()) return;
    await _outbox.flush();
    await _catalog.refreshStale();
    for (final c in _caches) {
      await c.refreshStale();
    }
    await _catalog.maintain();
  }).whenComplete(() => _cycle = null);

  static Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } on Object {
      // Сбой фонового прохода не должен ронять приложение; состояние отражают кэш и очередь.
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}
