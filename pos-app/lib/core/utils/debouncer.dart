// Debounce ввода (поиск — 300 мс, D-31; изменения корзины перед outbox — 500 мс, ядро §19.4).
import 'dart:async';

final class Debouncer {
  Debouncer(this.delay);

  /// Поиск по каталогу (D-31, RL-SEARCH).
  static const Duration search = Duration(milliseconds: 300);

  /// Изменения корзины перед постановкой в outbox (07 §11.4, ядро §19.4).
  static const Duration cart = Duration(milliseconds: 500);

  final Duration delay;
  Timer? _timer;

  /// Запланировать [action]; предыдущий незавершённый вызов отменяется.
  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Есть запланированный вызов.
  bool get isPending => _timer?.isActive ?? false;

  /// Отменить запланированный вызов.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Освободить ресурсы (то же, что [cancel]).
  void dispose() => cancel();
}
