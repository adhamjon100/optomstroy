import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/app.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/design_system/gallery/ds_gallery_screen.dart';

import '../support/fake_backend_health.dart';

void main() {
  test('/dev/gallery регистрируется только в debug-сборке', () {
    final debugPaths = devRoutes(debug: true).whereType<GoRoute>().map((r) => r.path);
    expect(debugPaths, [DsGalleryScreen.routePath]);
    expect(devRoutes(debug: false), isEmpty);
  });

  testWidgets('debug: /dev/gallery открывается без сессии (витрина DS, RM-C-003)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe())],
        child: const App(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(App)));
    container.read(appRouterProvider).go(DsGalleryScreen.routePath);
    // В витрине есть бесконечные анимации (скелетоны, прогресс) — pumpAndSettle не завершится.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(DsGalleryScreen), findsOneWidget);
  });
}
