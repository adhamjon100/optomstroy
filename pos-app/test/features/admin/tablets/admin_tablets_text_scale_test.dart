// SCR-54 «Планшеты магазина» на compact 360 × 760 при масштабе текста 1.3× и 1.5× (03 A11Y-005: текст до 1.3× без
// потери функций; 02 SCR-54.2 — карточки на compact; AC-UI-54-013 — напоминание о сроке подключения): предупреждение
// «Подключение заканчивается {date}. Подключите планшет заново» переносится целиком, имена планшетов — до 2 строк без
// многоточия. Шрифт Inter, данные синтетические (те же планшеты, что в golden SCR-54).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_screen.dart';

import '../../../design_system/ds_test_support.dart' show loadInterFont;
import '../support/fake_admin_repository.dart';
import '../support/fake_admin_tablets.dart';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('ru'));

const Size _compact = Size(360, 760);

/// Подключён и закреплён; не закреплён, срок подключения кончается через 20 дней, старая версия; отключён.
List<StoreTablet> _tablets() => <StoreTablet>[
  tablet(
    tabletAId,
    lastSeenAt: t0.subtract(const Duration(minutes: 3)),
    lockTaskEnabled: true,
    expiresAt: t0.add(const Duration(days: 200)),
  ),
  tablet(
    tabletBId,
    name: 'Планшет у кассы',
    warehouseId: warehouseSecondId,
    lastSeenAt: t0.subtract(const Duration(hours: 2)),
    appVersion: '1.3.9+80',
    expiresAt: t0.add(const Duration(days: 20)),
  ),
  tablet(
    '0192f3a1-6c3e-7a1b-9f00-0000000005c1',
    name: 'Планшет склада',
    status: StoreTabletStatus.revoked,
    lastSeenAt: t0.subtract(const Duration(days: 10)),
    lockTaskEnabled: true,
  ),
];

Future<void> _pump(WidgetTester tester, double scale) async {
  tester.view
    ..physicalSize = _compact
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<Override> overrides = tabletsOverrides(
    FakeAdminTabletsRepository(tablets: _tablets()),
    device: FakeKioskDevice(),
    recommendedVersion: '1.4.2',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (BuildContext context, Widget? app) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
          child: app!,
        ),
        home: const AdminTabletsScreen(),
      ),
    ),
  );
  await settle(tester);
}

/// Абзац [finder] показан целиком: строки не обрезаны, многоточия нет.
void _whole(WidgetTester tester, Finder finder, String what) {
  expect(finder, findsOneWidget, reason: what);
  final RenderParagraph p = tester.renderObject<RenderParagraph>(finder);
  expect(p.didExceedMaxLines, isFalse, reason: '$what не обрезан');
  final String text = p.text.toPlainText();
  for (final TextBox b in p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length))) {
    expect(b.bottom, lessThanOrEqualTo(p.size.height + 0.5), reason: '$what виден по высоте');
  }
}

void main() {
  setUpAll(loadInterFont);

  for (final double scale in <double>[1.3, 1.5]) {
    testWidgets('A11Y-005 AC-UI-54-013 compact ×$scale: напоминание о сроке переносится целиком, имена планшетов — без '
        'многоточия', (tester) async {
      await _pump(tester, scale);
      final String reminder = _l10n.kiosk_admin_expires_soon(AdminFormat.date(t0.add(const Duration(days: 20))));
      _whole(
        tester,
        find.descendant(of: find.byKey(AdminTabletsScreen.expiryKey(tabletBId)), matching: find.text(reminder)),
        'напоминание о сроке',
      );
      for (final String name in <String>['Планшет у входа', 'Планшет у кассы', 'Планшет склада']) {
        _whole(tester, find.text(name), name);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
