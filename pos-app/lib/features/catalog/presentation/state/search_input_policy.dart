// Правила строки поиска (D-31, CAT-002; 02 SCR-10.4.A, SCR-11.4): debounce 300 мс, минимум 2 символа
// (строка только из цифр — артикул/штрихкод — с 1 символа), Enter — немедленно, до 100 символов,
// на сервер — исходная строка без пробелов по краям. Устаревшие ответы отбрасывает список
// (номер поколения запроса). Чистый Dart + таймер `Debouncer` core/utils.
import 'dart:math' as math;

import 'package:optomstroy/core/utils/debouncer.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';

abstract final class SearchInputPolicy {
  /// Пауза перед запросом.
  static const Duration debounce = Debouncer.search;

  /// Длина строки, длиннее — обрезается [ТИПОВО].
  static const int maxLength = 100;

  /// Строка для запроса: без пробелов по краям, ≤ [maxLength].
  static String normalize(String raw) {
    final String t = raw.trim();
    return t.length > maxLength ? t.substring(0, maxLength) : t;
  }

  /// Только цифры (артикул/штрихкод — поиск с 1 символа).
  static bool isDigitsOnly(String q) => q.isNotEmpty && RegExp(r'^\d+$').hasMatch(q);

  /// Сколько символов не хватает до запроса (0 — запрос допустим).
  static int missingChars(String raw) {
    final String q = normalize(raw);
    if (isDigitsOnly(q)) {
      return 0;
    }
    return math.max(0, SearchQuery.minLength - q.length);
  }

  /// Запрос допустим.
  static bool canSearch(String raw) => normalize(raw).isNotEmpty && missingChars(raw) == 0;
}

/// Ввод строки поиска с debounce: [onQuery] вызывается не чаще раза в [SearchInputPolicy.debounce]
/// и только для допустимой строки; Enter ([submit]) — сразу, таймер сбрасывается.
final class SearchInputController {
  SearchInputController({required this.onQuery, Duration delay = SearchInputPolicy.debounce})
    : _debouncer = Debouncer(delay);

  final void Function(String query) onQuery;
  final Debouncer _debouncer;
  String _last = '';

  /// Последняя отправленная строка.
  String get lastQuery => _last;

  /// Изменение текста.
  void changed(String raw) {
    final String q = SearchInputPolicy.normalize(raw);
    if (!SearchInputPolicy.canSearch(q)) {
      _debouncer.cancel();
      return;
    }
    _debouncer(() => _emit(q));
  }

  /// Enter — немедленный поиск (если строка допустима).
  void submit(String raw) {
    _debouncer.cancel();
    final String q = SearchInputPolicy.normalize(raw);
    if (SearchInputPolicy.canSearch(q)) {
      _emit(q, force: true);
    }
  }

  /// Синхронизация с маршрутом (deep link / «Назад») без запроса.
  void reset(String query) {
    _debouncer.cancel();
    _last = SearchInputPolicy.normalize(query);
  }

  void _emit(String q, {bool force = false}) {
    if (!force && q == _last) {
      return;
    }
    _last = q;
    onQuery(q);
  }

  void dispose() => _debouncer.dispose();
}
