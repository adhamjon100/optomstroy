// Время на экранах — только время магазина Asia/Bishkek (UTC+6 круглый год; 02 §0.1, core/utils/clock.dart):
// презентация не читает пояс машины (`.toLocal()`) и системные часы (`DateTime.now()`); «сейчас» приходит из
// `clockProvider` / `syncNowProvider` вызывающего кода. Причина правила — golden-эталоны SCR-43/45/23 падали при
// смене пояса Windows (+04:00 → +06:00) и на Linux-CI (UTC), а метка «сегодня/с датой» зависела от даты прогона.
//
// 1. Страж: в lib/design_system/** и lib/features/**/presentation/** нет `.toLocal()` и `DateTime.now`.
// 2. Юнит-тесты `dsTimeLabel` и форматов времени: одинаковый вывод для любого представления момента (UTC или
//    местное время машины) и при любом поясе машины; дата печатается только для «не сегодня» относительно nowUtc.
// Тест-кейсы 12_TEST_PLAN: T-DS-102 (время на экранах — по часам магазина).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_formatters.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';

import 'ds_test_support.dart';

/// Белый список: файл → число допустимых вхождений и почему. Здесь только интервалы UI (защита от двойного
/// нажатия, окна «Назад», пределы опроса) — разность двух моментов, а не время на экране; пояс на них не влияет.
/// Источник времени `SystemClock` (core/utils/clock.dart) и метки журналов/токенов в auth_interceptor и
/// logging_interceptor (core/network) лежат вне проверяемых каталогов и в список не входят.
const Map<String, ({int count, String why})> _allowed = <String, ({int count, String why})>{
  'lib/features/auth/presentation/mascot/mascot_controller.dart': (
    count: 1,
    why: 'интервал кивка персонажа при вводе (анимация); в тестах момент передаётся параметром `now`',
  ),
  'lib/features/cart/presentation/widgets/cart_panel_view.dart': (
    count: 3,
    why: 'защита от повторного «Создать заказ» (_checkoutGuard, AC-UI-20-016) — интервал между нажатиями',
  ),
  'lib/features/catalog/presentation/screens/customer_home_view.dart': (
    count: 1,
    why: 'блокировка повторной навигации 300 мс (_navLocked, SCR-50)',
  ),
  'lib/features/catalog/presentation/widgets/back_to_exit_scope.dart': (
    count: 1,
    why: 'окно двойного «Назад» для выхода из приложения (Android)',
  ),
  'lib/features/catalog/presentation/widgets/catalog_workspace.dart': (
    count: 1,
    why: 'блокировка повторного push 300 мс (_navLocked, SCR-10.11)',
  ),
  'lib/features/checkout/presentation/controllers/order_created_controller.dart': (
    count: 2,
    why: 'предел длительности опроса статуса заказа (orderPollLimit) — интервал, не отображение',
  ),
  'lib/features/home/presentation/screens/customer_home_screen.dart': (
    count: 1,
    why: 'окно двойного «Назад» для выхода из приложения (SCR-50)',
  ),
};

final RegExp _forbidden = RegExp(r'\.toLocal\b|\bDateTime\.now\b');

bool _scanned(String path) =>
    path.startsWith('lib/design_system/') || (path.startsWith('lib/features/') && path.contains('/presentation/'));

/// Вхождения запрещённых вызовов по файлам (строки-комментарии не считаются).
Map<String, List<String>> _occurrences() {
  final Map<String, List<String>> found = <String, List<String>>{};
  for (final FileSystemEntity e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart') || e.path.endsWith('.g.dart')) continue;
    final String path = e.path.replaceAll(r'\', '/');
    if (!_scanned(path)) continue;
    final List<String> lines = e.readAsLinesSync();
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trimLeft();
      if (line.startsWith('//')) continue;
      final String code = line.split(' // ').first;
      if (_forbidden.hasMatch(code)) (found[path] ??= <String>[]).add('$path:${i + 1}: ${lines[i].trim()}');
    }
  }
  return found;
}

/// Вычисляет [f] внутри приложения с локалью `ru` (форматы `intl` нужны с данными локали).
Future<T> _inApp<T>(WidgetTester tester, T Function(BuildContext context) f) async {
  late T result;
  await pumpDs(
    tester,
    Builder(
      builder: (BuildContext context) {
        result = f(context);
        return const SizedBox.shrink();
      },
    ),
  );
  return result;
}

void main() {
  group('страж: время в презентации — только Asia/Bishkek и внедрённые часы', () {
    test('нет .toLocal() и DateTime.now в lib/design_system/** и lib/features/**/presentation/**', () {
      final Map<String, List<String>> found = _occurrences();
      final List<String> violations = <String>[
        for (final MapEntry<String, List<String>> e in found.entries)
          if ((_allowed[e.key]?.count ?? 0) != e.value.length) ...e.value,
      ];
      expect(
        violations,
        isEmpty,
        reason:
            'Время на экране — DsBishkekTime / AdminFormat.wall / dsTimeLabel(nowUtc: …), «сейчас» — из '
            'clockProvider (02 §0.1). Интервал UI — добавьте файл в _allowed с причиной.',
      );
    });

    test('белый список актуален: каждый файл существует и ещё содержит вхождения', () {
      final Map<String, List<String>> found = _occurrences();
      for (final MapEntry<String, ({int count, String why})> e in _allowed.entries) {
        expect(File(e.key).existsSync(), isTrue, reason: '${e.key} удалён — уберите из _allowed');
        expect(found[e.key]?.length ?? 0, e.value.count, reason: '${e.key}: ${e.value.why}');
        expect(e.value.why.length, greaterThan(10));
      }
    });
  });

  group('dsTimeLabel — время магазина, «сегодня» относительно nowUtc', () {
    // 09:12 UTC = 15:12 Бишкек. Эталоны SCR-43 снимались при поясе машины +04:00 («13:12»), сейчас +06:00.
    final DateTime asOf = DateTime.utc(2026, 10, 19, 9, 12);
    final FixedClock clock = FixedClock(DateTime.utc(2026, 10, 19, 10));

    testWidgets('тот же день Бишкека — только время; вывод не зависит от представления момента', (tester) async {
      final List<String> out = await _inApp(
        tester,
        (BuildContext context) => <String>[
          dsTimeLabel(context, asOf, nowUtc: clock.nowUtc()),
          // То же мгновение в местном времени машины (любой пояс) — тот же вывод.
          dsTimeLabel(context, asOf.toLocal(), nowUtc: clock.nowUtc().toLocal()),
          dsTimeLabel(context, asOf.add(const Duration(hours: 5)), nowUtc: clock.nowUtc()),
        ],
      );
      expect(out, <String>['15:12', '15:12', '20:12']);
      // Пояс машины (каким бы он ни был) — не источник: «15:12» только у Бишкека.
      expect(DsBishkekTime.offset, const Duration(hours: 6));
    });

    testWidgets('дата — только для «не сегодня» по Бишкеку, даже если по UTC день тот же', (tester) async {
      final List<String> out = await _inApp(
        tester,
        (BuildContext context) => <String>[
          // 23:59 19 окт. Бишкека; «сейчас» — 00:01 20 окт. Бишкека (по UTC оба — 19 окт.).
          dsTimeLabel(context, DateTime.utc(2026, 10, 19, 17, 59), nowUtc: DateTime.utc(2026, 10, 19, 18, 1)),
          // 00:30 20 окт. Бишкека (по UTC — ещё 19 окт.); «сейчас» — 11:00 20 окт. Бишкека.
          dsTimeLabel(context, DateTime.utc(2026, 10, 19, 18, 30), nowUtc: DateTime.utc(2026, 10, 20, 5)),
          // Неделю назад.
          dsTimeLabel(context, asOf.subtract(const Duration(days: 7)), nowUtc: clock.nowUtc()),
        ],
      );
      expect(out, <String>['19 окт., 23:59', '00:30', '12 окт., 15:12']);
    });

    testWidgets('без «сейчас» — всегда с датой (DS не читает системные часы)', (tester) async {
      final List<String> out = await _inApp(
        tester,
        (BuildContext context) => <String>[
          dsDateTimeLabel(context, asOf),
          dsTimeLabelOrFull(context, asOf, null),
          dsTimeLabelOrFull(context, asOf, clock.nowUtc()),
        ],
      );
      expect(out, <String>['19 окт., 15:12', '19 окт., 15:12', '15:12']);
    });

    testWidgets('OfflineBanner и SyncIndicator: метка по FixedClock вызывающего кода', (tester) async {
      final List<String> out = await _inApp(
        tester,
        (BuildContext context) => <String>[
          OfflineBanner.textOf(context, OfflineBannerVariant.offline, asOf, now: clock.nowUtc()),
          OfflineBanner.textOf(context, OfflineBannerVariant.offline, asOf),
          SyncIndicator.labelOf(context, SyncIndicatorVariant.ok, time: asOf, now: clock.nowUtc()),
          SyncIndicator.labelOf(context, SyncIndicatorVariant.stale, time: asOf, inline: true, now: clock.nowUtc()),
        ],
      );
      expect(out[0], contains('15:12'));
      expect(out[0], isNot(contains('окт.')));
      expect(out[1], contains('19 окт., 15:12'));
      expect(out[2], contains('15:12'));
      expect(out[3], contains('15:12'));
    });
  });

  group('форматы времени экранов — Asia/Bishkek', () {
    final DateTime at = DateTime.utc(2026, 10, 22, 7, 5, 9); // 13:05:09 Бишкек

    test('CartFormats, CatalogFormats, ProductFormat, AdminFormat — одно и то же время магазина', () {
      for (final DateTime t in <DateTime>[at, at.toLocal()]) {
        expect(CartFormats.time(t), '13:05');
        expect(CatalogFormats.time(t), '13:05');
        expect(ProductFormat.time(t), '13:05');
        expect(DsBishkekTime.time(t), '13:05');
        expect(AdminFormat.timeSeconds(t), '13:05:09');
        expect(AdminFormat.wall(t).hour, 13);
      }
      // Полночь Бишкека: по UTC ещё предыдущий день.
      expect(DsBishkekTime.date(DateTime.utc(2026, 10, 21, 18, 30)), '22.10.2026');
      expect(AdminFormat.date(DateTime.utc(2026, 10, 21, 18, 30)), '22.10.2026');
    });

    testWidgets('SettingsTexts — дата и время магазина', (tester) async {
      final List<String> out = await _inApp(
        tester,
        (BuildContext context) => <String>[
          SettingsTexts.dateTime(DateTime.utc(2026, 10, 21, 18, 30), 'ru'),
          SettingsTexts.date(DateTime.utc(2026, 10, 21, 18, 30), 'ru'),
        ],
      );
      expect(out[0], '22 окт., 00:30');
      expect(out[1], startsWith('22 окт.'));
      expect(out[1], contains('2026'));
    });
  });
}
