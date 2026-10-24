// Сигнал отмены запроса для портов domain (06 §6.7 «CancelToken — поиск с debounce 300 мс отменяет предыдущий
// запрос», D-31; 02 SCR-31.11, SCR-33.11, SCR-47.11). domain — чистый Dart (FL-01) и не знает dio: presentation
// создаёт [CancelSignal] на запрос и отменяет его при новом запросе и при уходе с экрана, слой data переводит сигнал
// в `CancelToken` dio (core/network/cancel_signal_dio.dart). Ответ отменённого запроса вызывающий отбрасывает сам
// (номер поколения) и пользователю как ошибку не показывает.
import 'dart:async';

/// Отмена одного запроса.
final class CancelSignal {
  final Completer<void> _done = Completer<void>();

  /// Отменён.
  bool get isCancelled => _done.isCompleted;

  /// Завершается при отмене.
  Future<void> get whenCancelled => _done.future;

  /// Отменить (повторный вызов ничего не делает).
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Последовательность запросов одного экрана: каждый новый [next] отменяет предыдущий сигнал.
final class CancelSignalSeries {
  CancelSignal? _current;

  /// Новый сигнал; предыдущий отменяется.
  CancelSignal next() {
    _current?.cancel();
    return _current = CancelSignal();
  }

  /// Отменить текущий (уход с экрана).
  void cancel() {
    _current?.cancel();
    _current = null;
  }
}
