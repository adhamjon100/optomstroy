// Наблюдение за сетью (06 §6.7, §6.12; R3 §8).
//
// `connectivity_plus` — только сигнал «сетевой интерфейс появился/пропал» (триггер
// outbox и синхронизации). Фактическая доступность backend определяется исходом
// запросов (успешный `GET /health` или любой успешный ответ):
//   нет интерфейса / ошибка соединения → offline (OfflineBanner, SCR-90);
//   таймаут ответа / 502–504 при живом соединении → serverDown;
//   любой ответ сервера → online.
// Таймаут long-poll — не ошибка и статус не меняет (фильтрует вызывающий).
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Доступность backend для UI.
enum OnlineStatus {
  /// Ещё нет данных (старт или сеть только что появилась).
  unknown,
  online,
  offline,

  /// Соединение есть, но сервер не отвечает вовремя.
  serverDown,
}

/// Исход запроса для [ConnectivityWatcher.report].
enum RequestOutcome {
  /// Получен любой HTTP-ответ сервера (в том числе 4xx).
  responded,

  /// Соединение не установлено.
  connectionFailed,

  /// Таймаут ответа или 502/503/504.
  serverUnavailable,
}

/// Источник сигнала о сетевом интерфейсе (в тестах — фейк).
abstract interface class NetworkSignalSource {
  /// Есть ли сейчас хотя бы один сетевой интерфейс.
  Future<bool> hasNetwork();

  /// Изменения наличия интерфейса.
  Stream<bool> get changes;
}

/// Реализация на `connectivity_plus`.
final class ConnectivityPlusSource implements NetworkSignalSource {
  ConnectivityPlusSource([Connectivity? connectivity]) : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _anyInterface(List<ConnectivityResult> results) => results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> hasNetwork() async => _anyInterface(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get changes => _connectivity.onConnectivityChanged.map(_anyInterface).distinct();
}

final class ConnectivityWatcher {
  ConnectivityWatcher(this._source);

  final NetworkSignalSource _source;
  final StreamController<OnlineStatus> _status = StreamController<OnlineStatus>.broadcast();
  final StreamController<void> _restored = StreamController<void>.broadcast();
  StreamSubscription<bool>? _subscription;
  OnlineStatus _current = OnlineStatus.unknown;
  bool _hasNetwork = true;

  /// Текущий статус.
  OnlineStatus get current => _current;

  /// Изменения статуса (без повторов).
  Stream<OnlineStatus> get status => _status.stream;

  /// Сетевой интерфейс появился после отсутствия — триггер `GET /health`,
  /// `OutboxQueue.flush()` и `SyncScheduler.refreshStale()` (06 §6.12).
  Stream<void> get networkRestored => _restored.stream;

  /// Начать наблюдение.
  Future<void> start() async {
    await _subscription?.cancel();
    _subscription = _source.changes.listen(_onSignal);
    _onSignal(await _source.hasNetwork());
  }

  /// Исход запроса к backend.
  void report(RequestOutcome outcome) {
    switch (outcome) {
      case RequestOutcome.responded:
        _set(OnlineStatus.online);
      case RequestOutcome.connectionFailed:
        _set(OnlineStatus.offline);
      case RequestOutcome.serverUnavailable:
        _set(_hasNetwork ? OnlineStatus.serverDown : OnlineStatus.offline);
    }
  }

  void _onSignal(bool hasNetwork) {
    final restored = hasNetwork && !_hasNetwork;
    _hasNetwork = hasNetwork;
    if (!hasNetwork) {
      _set(OnlineStatus.offline);
    } else if (restored) {
      _set(OnlineStatus.unknown);
      _restored.add(null);
    }
  }

  void _set(OnlineStatus value) {
    if (value == _current) return;
    _current = value;
    _status.add(value);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _status.close();
    await _restored.close();
  }
}
