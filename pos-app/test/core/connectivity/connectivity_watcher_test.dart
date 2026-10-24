// ConnectivityWatcher (06 §6.7, §6.12): сигнал интерфейса + исходы запросов.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';

final class FakeSignal implements NetworkSignalSource {
  FakeSignal(this.initial);

  bool initial;

  // Закрывается в тестах после использования.
  // ignore: close_sinks
  final StreamController<bool> controller = StreamController<bool>.broadcast();

  @override
  Future<bool> hasNetwork() async => initial;

  @override
  Stream<bool> get changes => controller.stream;
}

void main() {
  test('старт без сети → offline; появление сети → unknown + networkRestored; ответ → online', () async {
    final signal = FakeSignal(false);
    final watcher = ConnectivityWatcher(signal);
    final statuses = <OnlineStatus>[];
    var restored = 0;
    watcher.status.listen(statuses.add);
    watcher.networkRestored.listen((_) => restored++);

    await watcher.start();
    expect(watcher.current, OnlineStatus.offline);

    signal.controller.add(true);
    await pumpEventQueue();
    expect(watcher.current, OnlineStatus.unknown);
    expect(restored, 1);

    watcher.report(RequestOutcome.responded);
    watcher.report(RequestOutcome.responded);
    expect(watcher.current, OnlineStatus.online);

    watcher.report(RequestOutcome.serverUnavailable);
    expect(watcher.current, OnlineStatus.serverDown);
    watcher.report(RequestOutcome.connectionFailed);
    expect(watcher.current, OnlineStatus.offline);
    await pumpEventQueue();
    expect(statuses, [
      OnlineStatus.offline,
      OnlineStatus.unknown,
      OnlineStatus.online,
      OnlineStatus.serverDown,
      OnlineStatus.offline,
    ]);

    signal.controller.add(true); // сеть уже была — не «восстановление»
    await pumpEventQueue();
    expect(restored, 1);

    signal.controller.add(false);
    await pumpEventQueue();
    watcher.report(RequestOutcome.serverUnavailable);
    expect(watcher.current, OnlineStatus.offline, reason: 'без интерфейса таймаут = offline');

    await watcher.start(); // повторный старт переподписывается
    await watcher.dispose();
    await signal.controller.close();
  });

  test('ConnectivityPlusSource создаётся без обращения к платформе', () {
    expect(ConnectivityPlusSource(), isA<NetworkSignalSource>());
  });
}
