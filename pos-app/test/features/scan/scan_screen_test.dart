// Widget-тесты SCR-17 (RM-E-010): нет разрешения, не найдено, найдено → переход в SCR-14,
// Windows (камеры нет), режимы order/test, серия, ошибка проверки, очередь и подавление повторов.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

import 'support/scan_fakes.dart';

void main() {
  late FakeBarcodeCamera camera;
  late FakeScanLookup lookup;
  late FakeScanCart cart;
  late int settingsOpened;

  setUp(() {
    camera = FakeBarcodeCamera();
    lookup = FakeScanLookup()..online[eanFound] = const Success<ScanLookupResult>(frap);
    cart = FakeScanCart();
    settingsOpened = 0;
  });

  Future<void> openScanner(
    WidgetTester tester, {
    String location = '/scan?mode=search',
    bool cameraSupported = true,
    bool withCart = false,
    PopResultHolder? popResult,
    bool series = false,
  }) async {
    setCompact(tester);
    await tester.pumpWidget(
      scanTestApp(
        scanLocation: location,
        popResult: popResult,
        overrides: [
          cameraScannerSupportedProvider.overrideWithValue(cameraSupported),
          barcodeCameraFactoryProvider.overrideWithValue(({required bool includeQr}) => camera),
          scanBarcodeLookupProvider.overrideWithValue(lookup),
          appSettingsLauncherProvider.overrideWithValue(() async {
            settingsOpened++;
            return false;
          }),
          if (withCart) scanCartPortProvider.overrideWithValue(cart),
        ],
      ),
    );
    await tester.tap(find.text('open-scan'));
    await tester.pumpAndSettle();
    if (series) {
      await tester.tap(find.byKey(const ValueKey<String>('scan-series')));
      await tester.pump();
    }
  }

  /// Код в 2 кадрах подряд — принимается (CameraCodeFilter).
  Future<void> detect(
    WidgetTester tester,
    String value, {
    CameraBarcodeFormat format = CameraBarcodeFormat.ean13,
  }) async {
    camera.emit(value, format: format);
    await tester.pump();
    camera.emit(value, format: format);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('нет разрешения камеры → EmptyState «Камера недоступна» + «Открыть настройки», «Ввести вручную»', (
    tester,
  ) async {
    camera.startStatus = CameraStatus.permissionDenied;
    await openScanner(tester);

    expect(find.byKey(const ValueKey<String>('scan-no-permission')), findsOneWidget);
    expect(find.text(ru.ds_empty_no_camera_title), findsOneWidget);
    expect(find.text(ru.scan_no_camera_body), findsOneWidget);
    expect(find.text(ru.scan_manual_entry), findsOneWidget);
    expect(camera.startCalls, 1);

    // «Открыть настройки»: настройки ОС не открылись — повторный запуск камеры (повторный запрос).
    camera.startStatus = CameraStatus.running;
    await tester.tap(find.text(ru.scan_open_settings));
    await tester.pumpAndSettle();
    expect(settingsOpened, 1);
    expect(camera.startCalls, 2);
    expect(find.byKey(const ValueKey<String>('scan-no-permission')), findsNothing);
    expect(find.text(ru.scan_hint), findsOneWidget);
  });

  testWidgets('нет разрешения → «Ввести вручную» закрывает камеру и открывает поиск SCR-11', (tester) async {
    camera.startStatus = CameraStatus.permissionDenied;
    await openScanner(tester);
    await tester.tap(find.text(ru.scan_manual_entry));
    await tester.pumpAndSettle();
    expect(find.text('search:/catalog/search'), findsOneWidget);
  });

  testWidgets('не найдено → карточка «Штрихкод … не найден» 3 с, сканирование продолжается', (tester) async {
    await openScanner(tester);
    expect(find.text(ru.scan_title), findsOneWidget);

    await detect(tester, eanMissing);
    expect(lookup.onlineCalls, <String>[eanMissing]);
    expect(find.text(ru.scan_not_found(eanMissing)), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('scan-screen')), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text(ru.scan_not_found(eanMissing)), findsNothing);
    expect(find.byKey(const ValueKey<String>('scan-screen')), findsOneWidget);
  });

  testWidgets('найдено (серия выкл.) → экран закрывается, открывается SCR-14 с вариантом', (tester) async {
    final pop = PopResultHolder();
    await openScanner(tester, popResult: pop);

    await detect(tester, eanFound);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('scan-screen')), findsNothing);
    expect(find.text('product:/catalog/p/p-frap?variantId=v-frap-chrome'), findsOneWidget);
    expect(pop.returned, isTrue);
    expect((pop.value! as ScannedProduct).result.productId, 'p-frap');
    expect(camera.disposed, isTrue);
  });

  testWidgets('один кадр не принимается; тот же код в рамке не ищется повторно', (tester) async {
    await openScanner(tester, series: true);
    camera.emit(eanMissing);
    await tester.pump();
    expect(lookup.onlineCalls, isEmpty);

    await detect(tester, eanMissing);
    await detect(tester, eanMissing);
    await detect(tester, eanMissing);
    expect(lookup.onlineCalls, <String>[eanMissing]);
  });

  testWidgets('серия вкл. → карточка «Открыть карточку», экран не закрывается; кнопка ведёт в SCR-14', (tester) async {
    await openScanner(tester, series: true);
    await detect(tester, eanFound);

    expect(find.text(frap.productName), findsOneWidget);
    expect(find.text('F4252 · $eanFound'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('scan-screen')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('scan-open-product')));
    await tester.pumpAndSettle();
    expect(find.text('product:/catalog/p/p-frap?variantId=v-frap-chrome'), findsOneWidget);
  });

  testWidgets('ошибка сервера → «Не удалось проверить штрихкод · Повторить», повтор находит товар', (tester) async {
    lookup.online[eanFound] = const FailureResult<ScanLookupResult>(ServerFailure(code: 'INTERNAL', status: 500));
    await openScanner(tester, series: true);
    await detect(tester, eanFound);
    expect(find.text(ru.scan_lookup_error), findsOneWidget);

    lookup.online[eanFound] = const Success<ScanLookupResult>(frap);
    await tester.tap(find.text(ru.ds_button_retry));
    await tester.pump();
    await tester.pump();
    expect(find.text(frap.productName), findsOneWidget);
    expect(lookup.onlineCalls, <String>[eanFound, eanFound]);
  });

  testWidgets('офлайн → найдено по кэшу с пометкой «Поиск по сохранённому каталогу от …»', (tester) async {
    lookup
      ..online.remove(eanFound)
      ..online[eanFound] = const FailureResult<ScanLookupResult>(NetworkFailure(NetworkFailureKind.offline))
      ..cached[eanFound] = ScanLookupResult(
        productId: frap.productId,
        productName: frap.productName,
        variantId: frap.variantId,
        fromCache: true,
        asOf: DateTime(2026, 10, 22, 9, 5),
      );
    await openScanner(tester, series: true);
    await detect(tester, eanFound);
    expect(find.text(ru.scan_offline_note('09:05')), findsOneWidget);
  });

  testWidgets('неверный формат кода → «Штрихкод не распознан», без запроса', (tester) async {
    await openScanner(tester);
    await detect(tester, '12');
    expect(find.text(ru.scan_invalid_code), findsOneWidget);
    expect(lookup.onlineCalls, isEmpty);
  });

  testWidgets('mode=add + корзина: +1 шаг с ключом идемпотентности, экран закрывается', (tester) async {
    final pop = PopResultHolder();
    await openScanner(tester, location: '/scan?mode=add', withCart: true, popResult: pop);
    await detect(tester, eanFound);
    await tester.pumpAndSettle();
    expect(cart.added, <String>['v-frap-chrome']);
    expect(cart.keys.single, isNotEmpty);
    expect((pop.value! as ScannedProduct).added, isTrue);
  });

  testWidgets('mode=add + серия: карточка «+1 шт · …» с «Отменить»', (tester) async {
    await openScanner(tester, location: '/scan?mode=add', withCart: true, series: true);
    await detect(tester, eanFound);
    expect(find.text(ru.scan_added(frap.productName, '1', 'шт')), findsOneWidget);
    await tester.tap(find.text(ru.ds_button_undo));
    await tester.pump();
    expect(cart.undone, 1);
  });

  testWidgets('mode=order: «Номер: …» 600 мс, затем pop(value) без запроса к каталогу; «Серия» скрыта', (tester) async {
    final pop = PopResultHolder();
    await openScanner(tester, location: '/scan?mode=order', popResult: pop);
    expect(find.text(ru.scan_title_order), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('scan-series')), findsNothing);

    await detect(tester, 'ORD-000123', format: CameraBarcodeFormat.qrCode);
    expect(find.text(ru.scan_order_value('ORD-000123')), findsOneWidget);
    expect(pop.returned, isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(pop.returned, isTrue);
    expect((pop.value! as ScannedCode).value, 'ORD-000123');
    expect(lookup.onlineCalls, isEmpty);
  });

  testWidgets('mode=test: «Распознано: {value} · {format}», pop(value, format); «Ввести вручную» скрыто', (
    tester,
  ) async {
    final pop = PopResultHolder();
    await openScanner(tester, location: '/scan?mode=test', popResult: pop);
    expect(find.text(ru.scan_title_test), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('scan-manual')), findsNothing);

    await detect(tester, eanFound);
    expect(find.text(ru.scan_test_result('EAN-13', eanFound)), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final r = pop.value! as ScannedCode;
    expect((r.value, r.format), (eanFound, 'EAN-13'));
    expect(lookup.onlineCalls, isEmpty);
  });

  testWidgets('Windows / нет камеры: камера не создаётся, EmptyState с подсказкой HID', (tester) async {
    await openScanner(tester, cameraSupported: false);
    expect(find.byKey(const ValueKey<String>('scan-unavailable')), findsOneWidget);
    expect(find.text(ru.scan_hid_waiting), findsOneWidget);
    expect(camera.startCalls, 0);
  });

  testWidgets('ошибка камеры → «Камера недоступна. Закройте другие приложения…» + «Повторить»', (tester) async {
    camera.startStatus = CameraStatus.failed;
    await openScanner(tester);
    expect(find.text(ru.scan_camera_error), findsOneWidget);
    camera.startStatus = CameraStatus.running;
    await tester.tap(find.text(ru.ds_button_retry));
    await tester.pumpAndSettle();
    expect(find.text(ru.scan_hint), findsOneWidget);
  });

  testWidgets('уход в фон останавливает камеру, возврат — запускает', (tester) async {
    await openScanner(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.stopCalls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.startCalls, 2);
  });

  testWidgets('крестик закрывает экран без результата', (tester) async {
    final pop = PopResultHolder();
    await openScanner(tester, popResult: pop);
    await tester.tap(find.byKey(const ValueKey<String>('scan-close')));
    await tester.pumpAndSettle();
    expect(pop.returned, isTrue);
    expect(pop.value, isNull);
  });
}
