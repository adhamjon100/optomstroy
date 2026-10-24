// 02 SCR-10.11, SCR-50.11/12: «Назад» на корне каталога (SCR-10) и главной клиента (SCR-50) — выход из приложения
// по двойному нажатию с подсказкой `home_back_to_exit` (Android); не на корне и не на Android — обычное «Назад».
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/back_to_exit_scope.dart';

import 'support/catalog_fakes.dart';

void main() {
  testWidgets('SCR-10 (Android): первое «Назад» — подсказка, второе в течение 2 с — выход', (tester) async {
    var exits = 0;
    setWindow(tester, kCompact);
    await tester.pumpWidget(catalogApp(CatalogHarness(), home: const CatalogScreen()));
    await settle(tester);
    final BackToExitScope scope = tester.widget<BackToExitScope>(find.byType(BackToExitScope));
    expect(scope.enabled, isTrue);
    // Подменить выход: тот же экран, но с фейковым SystemNavigator.pop.
    await tester.pumpWidget(
      catalogApp(
        CatalogHarness(),
        home: BackToExitScope(
          platform: TargetPlatform.android,
          exit: () async => exits++,
          child: const Scaffold(body: Text('SCR-10')),
        ),
      ),
    );
    await settle(tester);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(find.text('Нажмите ещё раз для выхода'), findsOneWidget);
    expect(exits, 0);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(exits, 1);
  });

  testWidgets('Windows: системного «Назад» нет — поведение не меняется', (tester) async {
    var exits = 0;
    await tester.pumpWidget(
      catalogApp(
        CatalogHarness(),
        home: BackToExitScope(
          platform: TargetPlatform.windows,
          exit: () async => exits++,
          child: const Scaffold(body: Text('SCR-10')),
        ),
      ),
    );
    await settle(tester);
    expect(tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop, isTrue);
    expect(exits, 0);
  });
}
