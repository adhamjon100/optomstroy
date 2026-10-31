// Кнопка сканера шапки каталога и шапки оболочки (UI-10-044, `handleCatalogScanButton`): камера есть
// (`cameraScannerSupportedProvider` — Android/iOS вне браузера) — SCR-17 `/scan?mode=search`; камеры нет (Windows, D-42;
// браузер веб-демо, в том числе на Android) — подсказка HID-сканера и фокус в поле поиска, без перехода.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/hardware/barcode_camera.dart' show cameraScannerSupportedOn;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';

Future<FocusNode> _pump(WidgetTester tester, {required bool cameraSupported}) async {
  final FocusNode focus = FocusNode();
  addTearDown(focus.dispose);
  final GoRouter router = GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => Scaffold(
          body: Column(
            children: <Widget>[
              TextField(focusNode: focus),
              Builder(
                builder: (BuildContext ctx) => TextButton(
                  onPressed: () => handleCatalogScanButton(ctx, focus, cameraSupported: cameraSupported),
                  child: const Text('scan'),
                ),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: '/scan',
        builder: (BuildContext context, GoRouterState state) =>
            Scaffold(body: Text('SCR-17 ${state.uri.queryParameters['mode']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  await tester.pumpAndSettle();
  return focus;
}

void main() {
  late AppLocalizations l10n;
  setUpAll(() async => l10n = await AppLocalizations.delegate.load(const Locale('ru')));

  testWidgets('камера есть — SCR-17 /scan?mode=search', (WidgetTester tester) async {
    await _pump(tester, cameraSupported: true);
    await tester.tap(find.text('scan'));
    await tester.pumpAndSettle();
    expect(find.text('SCR-17 search'), findsOneWidget);
    expect(find.text(l10n.catalog_scanner_hid_hint), findsNothing);
  });

  testWidgets('камеры нет (Windows, браузер) — подсказка HID-сканера, фокус в поле поиска, без перехода', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = await _pump(tester, cameraSupported: false);
    expect(focus.hasFocus, isFalse);
    await tester.tap(find.text('scan'));
    await tester.pump();
    expect(find.text(l10n.catalog_scanner_hid_hint), findsOneWidget);
    expect(focus.hasFocus, isTrue);
    expect(find.textContaining('SCR-17'), findsNothing);
  });

  test('признак камеры: браузер на Android/iOS — камеры нет; Android/iOS вне браузера — есть; Windows — нет', () {
    expect(cameraScannerSupportedOn(TargetPlatform.android, isWeb: true), isFalse);
    expect(cameraScannerSupportedOn(TargetPlatform.iOS, isWeb: true), isFalse);
    expect(cameraScannerSupportedOn(TargetPlatform.android, isWeb: false), isTrue);
    expect(cameraScannerSupportedOn(TargetPlatform.windows, isWeb: false), isFalse);
  });
}
