// Фейки для тестов фичи scan: камера, порт поиска по штрихкоду, порт корзины, приложение с роутером.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/screens/scan_screen.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

/// Камера: статус после `start()` задаёт тест ([startStatus]); кадры подаются [emit].
class FakeBarcodeCamera implements BarcodeCamera {
  FakeBarcodeCamera({
    this.startStatus = CameraStatus.running,
    this.torch = CameraTorch.off,
    CameraStatus initial = CameraStatus.idle,
  }) : _state = ValueNotifier<BarcodeCameraState>(BarcodeCameraState(status: initial, torch: torch));

  CameraStatus startStatus;
  final CameraTorch torch;
  int startCalls = 0;
  int stopCalls = 0;
  bool disposed = false;
  final ValueNotifier<BarcodeCameraState> _state;
  final StreamController<List<CameraDetection>> _frames = StreamController<List<CameraDetection>>.broadcast();

  @override
  ValueListenable<BarcodeCameraState> get state => _state;

  @override
  Stream<List<CameraDetection>> get detections => _frames.stream;

  @override
  Future<void> start() async {
    startCalls++;
    _state.value = BarcodeCameraState(status: startStatus, torch: torch);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _state.value = BarcodeCameraState(torch: torch);
  }

  @override
  Future<void> toggleTorch() async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await _frames.close();
  }

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand(key: ValueKey<String>('fake-preview'));

  /// Подаёт кадр с кодом [value] (формат EAN-13).
  void emit(String value, {CameraBarcodeFormat format = CameraBarcodeFormat.ean13}) =>
      _frames.add(<CameraDetection>[CameraDetection(value, format)]);
}

/// Порт поиска: ответы по значению.
class FakeScanLookup implements ScanBarcodeLookup {
  final Map<String, Result<ScanLookupResult>> online = <String, Result<ScanLookupResult>>{};
  final Map<String, ScanLookupResult?> cached = <String, ScanLookupResult?>{};
  final List<String> onlineCalls = <String>[];
  Completer<void>? gate;

  @override
  Future<Result<ScanLookupResult>> lookupOnline(String value) async {
    onlineCalls.add(value);
    final g = gate;
    if (g != null) await g.future;
    return online[value] ?? const FailureResult<ScanLookupResult>(ServerFailure(code: 'NOT_FOUND', status: 404));
  }

  @override
  Future<Result<ScanLookupResult?>> lookupCached(String value) async => Success<ScanLookupResult?>(cached[value]);
}

/// Корзина: запоминает добавления.
class FakeScanCart implements ScanCartPort {
  final List<String> added = <String>[];
  final List<String> keys = <String>[];
  int undone = 0;

  @override
  Future<Result<ScanAddReceipt>> addStep(ScanLookupResult result, {required String idempotencyKey}) async {
    added.add(result.variantId);
    keys.add(idempotencyKey);
    return const Success<ScanAddReceipt>(ScanAddReceipt(quantityLabel: '1', unitLabel: 'шт'));
  }

  @override
  Future<Result<void>> undo(ScanAddReceipt receipt) async {
    undone++;
    return const Success<void>(null);
  }
}

const String eanFound = '4607012345678';
const String eanMissing = '4600000000000';

const ScanLookupResult frap = ScanLookupResult(
  productId: 'p-frap',
  productName: 'Смеситель для кухни Frap F4252',
  sku: 'F4252',
  variantId: 'v-frap-chrome',
);

/// Последний результат `push('/scan')` из стартового экрана.
class PopResultHolder {
  Object? value;
  bool returned = false;
}

/// Приложение: `/` (кнопка открытия сканера) → `/scan`, плюс SCR-14 и SCR-11 как текст пути.
Widget scanTestApp({
  required List<Override> overrides,
  String scanLocation = '/scan?mode=search',
  PopResultHolder? popResult,
  Size? size,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final r = await context.push<Object?>(scanLocation);
                popResult
                  ?..value = r
                  ..returned = true;
              },
              child: const Text('open-scan'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/scan',
        builder: (context, state) => ScanScreen(mode: state.uri.queryParameters['mode']),
      ),
      GoRoute(
        path: '/catalog/p/:productId',
        builder: (context, state) => Scaffold(body: Text('product:${state.uri}')),
      ),
      GoRoute(
        path: '/catalog/search',
        builder: (context, state) => Scaffold(body: Text('search:${state.uri}')),
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
    ),
  );
}

/// Размер окна compact (телефон).
void setCompact(WidgetTester tester, {Size size = const Size(400, 860)}) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
}

AppLocalizations get ru => lookupAppLocalizations(const Locale('ru'));
