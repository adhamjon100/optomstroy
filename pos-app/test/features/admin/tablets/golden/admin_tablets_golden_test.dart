// Golden SCR-54 «Планшеты магазина» (02 ч. F SCR-54; 13 TAB-2-08, TAB-2-02; ADR-115 п. 26, п. 28): список планшетов у
// `admin` на трёх брейкпоинтах compact / medium / expanded (03 §7.2; D-18 — эталоны Windows) — строка «Подключён» с
// закреплением и сроком подключения, строка «Закрепление не включено» с напоминанием о сроке (за 30 дней и меньше) и
// «Нужна новая версия приложения», отключённый планшет (UI-54-007…010, AC-UI-54-012, AC-UI-54-013); `owner` — только
// список без действий (AC-UI-54-002); пустой список с «Сделать это устройство планшетом магазина» (AC-UI-54-014).
// На compact — карточки с меню, действия подключения в шапке (отказ подключения на compact — widget-тест T-KIOSK-002);
// compact при масштабе текста 1.3× и 1.5× — напоминание о сроке переносится целиком, имена — до 2 строк (03 A11Y-005).
// Палитра B, reduce-motion; данные синтетические (UUID-заглушки, имена планшетов; без телефонов и ФИО людей).
//
// Обновить эталоны: flutter test --tags golden test/features/admin/tablets/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_screen.dart';

import '../../support/fake_admin_repository.dart';
import '../../support/fake_admin_tablets.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

const String _tabletCId = '0192f3a1-6c3e-7a1b-9f00-0000000005c1';

/// Рекомендуемая версия Android (`GET /settings/public` → `recommendedAppVersion`): ниже — «Нужна новая версия».
const String _recommended = '1.4.2';

/// Три планшета: подключён и закреплён; не закреплён, срок подключения кончается через 20 дней, старая версия;
/// отключён администратором.
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
    _tabletCId,
    name: 'Планшет склада',
    status: StoreTabletStatus.revoked,
    lastSeenAt: t0.subtract(const Duration(days: 10)),
    lockTaskEnabled: true,
  ),
];

List<Override> _overrides({required AdminViewer me, required List<StoreTablet> tablets}) => tabletsOverrides(
  FakeAdminTabletsRepository(tablets: tablets),
  me: me,
  device: FakeKioskDevice(),
  recommendedVersion: _recommended,
);

Widget _app(Size size, List<Override> overrides, {double textScale = 1}) => SizedBox(
  width: size.width,
  height: size.height,
  child: ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          disableAnimations: true,
          padding: EdgeInsets.zero,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: const AdminTabletsScreen(),
    ),
  ),
);

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  for (final MapEntry<String, Size> w in _windows.entries) {
    unawaited(
      goldenTest(
        'SCR-54 admin · ${w.key}',
        fileName: 'admin_scr54_admin_${w.key}',
        constraints: BoxConstraints.tight(w.value),
        builder: () => _app(w.value, _overrides(me: adminViewer, tablets: _tablets())),
      ),
    );
  }
  for (final double scale in <double>[1.3, 1.5]) {
    final String suffix = 'text${(scale * 100).round()}';
    unawaited(
      goldenTest(
        'SCR-54 admin · compact · масштаб текста $scale',
        fileName: 'admin_scr54_admin_compact_$suffix',
        constraints: BoxConstraints.tight(_windows['compact']!),
        builder: () => _app(
          _windows['compact']!,
          _overrides(me: adminViewer, tablets: _tablets()),
          textScale: scale,
        ),
      ),
    );
  }
  unawaited(
    goldenTest(
      'SCR-54 owner · expanded',
      fileName: 'admin_scr54_owner_expanded',
      constraints: BoxConstraints.tight(_windows['expanded']!),
      builder: () => _app(_windows['expanded']!, _overrides(me: ownerViewer, tablets: _tablets())),
    ),
  );
  unawaited(
    goldenTest(
      'SCR-54 пустой список · medium',
      fileName: 'admin_scr54_empty_medium',
      constraints: BoxConstraints.tight(_windows['medium']!),
      builder: () => _app(_windows['medium']!, _overrides(me: adminViewer, tablets: const <StoreTablet>[])),
    ),
  );
}
