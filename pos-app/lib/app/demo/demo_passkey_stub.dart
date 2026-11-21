// Шлюз passkey веб-демо вне браузера (VM, тесты, Windows, Android): страницы нет (15 ADR-116 п. 1). Порт биометрии
// демо с ним отвечает «биометрии нет» без вызовов; тесты подставляют свой фейк `DemoPasskeyGateway`.
import 'package:optomstroy/app/demo/demo_passkey_gateway.dart';

/// Реализация для платформ без `dart:js_interop`.
DemoPasskeyGateway createPlatformDemoPasskeyGateway() => const UnavailableDemoPasskeyGateway();

/// Страницы нет: любой вызов — `not_available`.
final class UnavailableDemoPasskeyGateway implements DemoPasskeyGateway {
  const UnavailableDemoPasskeyGateway();

  @override
  bool get isAvailable => false;

  @override
  int? get protocol => null;

  @override
  Future<Map<String, Object?>> invoke(String method, [Map<String, Object?> args = const <String, Object?>{}]) async =>
      demoPasskeyNotAvailable;
}
