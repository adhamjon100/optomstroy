// Мост веб-демо к серверу в module Web Worker страницы (15 ADR-113 п. 2; 06 §6.10).
//
// JS-сторона — `globalThis.__posDemo` из demo/web/site-src/demo-bridge.js (протокол 1): `ready` (Promise),
// `isReady`, `offline`, `request({id, method, url, headers: [[k, v]], body, onStart})` → Promise
// `{status, headers: [[k, v]], body: Uint8Array}`, `cancel(id)`, `on('progress', fn)` → отписка. Ошибка запроса —
// `Error` с полем `code` ([DemoBridgeErrorCode]).
//
// Реализация выбирается условным импортом: в браузере — `dart:js_interop` (demo_bridge_web.dart), на VM и в тестах —
// заглушка без моста (demo_bridge_stub.dart). Тесты подставляют свой фейк [DemoBridge].
// Демо-код импортируется только из `app/demo/**` (DM-01, scripts/check_layers.py).
import 'dart:typed_data';

import 'package:optomstroy/app/demo/demo_bridge_stub.dart'
    if (dart.library.js_interop) 'package:optomstroy/app/demo/demo_bridge_web.dart'
    as platform;

/// Версия протокола `__posDemo.protocol`, которую понимает приложение.
const int demoBridgeProtocol = 1;

/// Коды ошибок моста (`Error.code` в demo-bridge.js).
abstract final class DemoBridgeErrorCode {
  /// Включено «Нет сети (имитация)» демо-панели.
  static const String offline = 'offline';

  /// Запрос отменён (`cancel(id)`).
  static const String cancelled = 'cancelled';

  /// Сервер демо остановился (`fatal` воркера).
  static const String fatal = 'fatal';

  /// Демо перенесено в другую вкладку или остановлено.
  static const String fenced = 'fenced';

  /// Мост отклонил запрос (чужой адрес, путь вне API, повтор id).
  static const String badRequest = 'bad_request';

  /// Нет моста или неизвестная ошибка.
  static const String unknown = 'unknown';
}

/// Отказ моста (отклонённый промис `request` или `ready`).
final class DemoBridgeException implements Exception {
  const DemoBridgeException(this.code, this.message);

  /// [DemoBridgeErrorCode].
  final String code;
  final String message;

  @override
  String toString() => 'DemoBridgeException($code): $message';
}

/// Запрос к серверу демо.
final class DemoBridgeRequest {
  const DemoBridgeRequest({
    required this.id,
    required this.method,
    required this.url,
    required this.headers,
    this.body,
    this.onStart,
  });

  /// Уникальный id запроса (для `cancel`).
  final String id;
  final String method;

  /// Путь с query того же origin: `/api/v1/…?…` или `/health`.
  final String url;

  /// Пары «имя, значение» в порядке Dio; повтор имени — отдельной парой.
  final List<(String, String)> headers;

  /// Копия тела в собственном буфере точной длины (мост передаёт её воркеру как `ArrayBuffer`; буфер запроса Dio не
  /// отсоединяется); `null` — без тела.
  final Uint8List? body;

  /// Запрос начал выполняться в воркере (`http:start`) или передан воркеру, если воркер этот сигнал не шлёт.
  final void Function()? onStart;
}

/// Ответ сервера демо: статус, заголовки и байты тела без преобразований.
final class DemoBridgeResponse {
  const DemoBridgeResponse({required this.status, required this.headers, required this.body});

  final int status;

  /// Пары «имя (нижний регистр), значение».
  final List<(String, String)> headers;
  final Uint8List body;
}

/// Мост страницы к серверу демо.
abstract interface class DemoBridge {
  /// Есть `globalThis.__posDemo`.
  bool get isAvailable;

  /// `__posDemo.protocol`; `null` — моста нет.
  int? get protocol;

  /// Origin сайта демо (`https://host[:port]`): только туда адаптер пускает запросы.
  String get origin;

  /// Воркер прислал `ready`.
  bool get isReady;

  /// Включено «Нет сети (имитация)».
  bool get offline;

  /// Завершается по `ready` воркера; ошибкой [DemoBridgeException] — по `fatal`.
  Future<void> whenReady();

  /// Подписка на прогресс холодного старта воркера (`progress`); возвращает отписку.
  void Function() onProgress(void Function() listener);

  /// Отправить запрос; ошибка — [DemoBridgeException].
  Future<DemoBridgeResponse> request(DemoBridgeRequest request);

  /// Отменить запрос [id]: ещё не начатый снимается из очереди, начатый получает `http:cancel`.
  void cancel(String id);
}

/// Мост этой платформы: в браузере — `globalThis.__posDemo`, на VM — заглушка без моста.
DemoBridge createDemoBridge() => platform.createPlatformDemoBridge();

/// Сообщить странице об ошибке запуска приложения: в браузере — `globalThis.__posShowStartError(message)` из
/// web/flutter_bootstrap.js (текст на экране загрузки; страница демо добавляет «Обновить страницу» и «Сбросить демо»);
/// на VM — ничего.
void reportDemoStartError(Object error) => platform.reportPlatformStartError('$error');
