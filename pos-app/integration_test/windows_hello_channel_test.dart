// T-BIO-032 (2) (12 §3.24; 13 §3.14 LF-1-06): канал `kg.optomstroy/windows_hello` (C++/WinRT,
// windows/runner/hello_channel.{h,cpp}) собран в приложение Windows и отвечает на `availability` без диалога.
// `createKey` и `sign` здесь не вызываются: они показывают диалог Windows Hello (в автоматических прогонах — никогда).
//
// Ожидаемое значение зависит от машины: у исполнителя Windows Hello не настроен (09 §9.2 W2: «на машине исполнителя
// ключи Windows Hello не поддерживаются») — 12 T-BIO-032 ждёт `device_not_present`. Значение для проверки передаётся
// `--dart-define=HELLO_EXPECTED_AVAILABILITY=<значение>`; без него тест проверяет только, что канал ответил.
//
// Запуск (Windows; без сервера и без данных приложения):
//   cd pos-app && flutter test integration_test/windows_hello_channel_test.dart -d windows \
//       --dart-define=HELLO_EXPECTED_AVAILABILITY=device_not_present
// После прогона удалить pos-app/build/windows и pos-app/.dart_tool/flutter_build (12 T-BIO-032 (3)).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_channel.dart';

const String _expected = String.fromEnvironment('HELLO_EXPECTED_AVAILABILITY');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'T-BIO-032 (2): availability канала kg.optomstroy/windows_hello — ответ натива без диалога Windows Hello',
    (WidgetTester tester) async {
      final WindowsHelloStatus status = await WindowsHelloKeyChannel().availability();
      // Запись для отчёта прогона (без данных пользователя).
      // ignore: avoid_print
      print('kg.optomstroy/windows_hello availability: $status');
      expect(
        status.availability,
        isNot(WindowsHelloAvailability.unknown),
        reason: 'канал зарегистрирован в flutter_window.cpp и UserConsentVerifier ответил',
      );
      if (_expected.isNotEmpty) {
        expect(status.availability.value, _expected);
      }
      if (status.availability != WindowsHelloAvailability.available) {
        expect(
          status.supportsKey,
          isFalse,
          reason: 'без Windows Hello ключ W2 не предлагается — режим гейта или недоступно',
        );
      }
    },
    skip: !Platform.isWindows,
  );
}
