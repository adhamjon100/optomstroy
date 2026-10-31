// Мост веб-демо вне браузера (VM, тесты, Windows): моста нет (15 ADR-113 п. 1). `main_web_demo.dart` с ним не
// запускается (`StateError`), тесты подставляют свой фейк `DemoBridge`.
import 'package:optomstroy/app/demo/demo_bridge.dart';

/// Реализация для платформ без `dart:js_interop`.
DemoBridge createPlatformDemoBridge() => const UnavailableDemoBridge();

/// Страницы нет — сообщать некому.
void reportPlatformStartError(String message) {}

/// Моста нет: запросы отклоняются, origin не определён.
final class UnavailableDemoBridge implements DemoBridge {
  const UnavailableDemoBridge();

  static const String reason = 'мост веб-демо globalThis.__posDemo есть только в браузере на странице демо';

  @override
  bool get isAvailable => false;

  @override
  int? get protocol => null;

  @override
  String get origin => throw StateError(reason);

  @override
  bool get isReady => false;

  @override
  bool get offline => false;

  @override
  Future<void> whenReady() => Future<void>.error(const DemoBridgeException(DemoBridgeErrorCode.unknown, reason));

  @override
  void Function() onProgress(void Function() listener) => () {};

  @override
  Future<DemoBridgeResponse> request(DemoBridgeRequest request) =>
      Future<DemoBridgeResponse>.error(const DemoBridgeException(DemoBridgeErrorCode.unknown, reason));

  @override
  void cancel(String id) {}
}
