// F-flutter-ui-14 — 03 DS-025 / AC-DS-025: отступы презентации экранов этапа F (cart, checkout, orders, notifications,
// customers) — только токены `ds.space.1…10` (`context.space.sN`), без литералов в `EdgeInsets`. Значения вне шкалы
// 4/8/12/16/20/24/32/40/48/64, которые нельзя заменить без изменения макета, перечислены явно (бейдж 5, полосы
// списка 6) — владельцу 03 (F_spec_questions, раздел FIX).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _roots = <String>[
  'lib/features/cart/presentation',
  'lib/features/checkout/presentation',
  'lib/features/orders/presentation',
  'lib/features/notifications/presentation',
  'lib/features/customers/presentation',
];

/// Допустимые исключения вне шкалы: `файл:значения`.
const Set<String> _allowed = <String>{
  'cart_panel_view.dart:horizontal: 5',
  'order_created_screen.dart:vertical: 6',
  'checkout_sections.dart:vertical: 6, horizontal: 8',
  'order_sections.dart:top: 6',
  'notification_tile.dart:top: context.space.s1 / 2',
  'notification_tile.dart:top: context.space.s1 + 2',
};

final RegExp _insets = RegExp(r'EdgeInsets(?:Directional)?\.(?:all|symmetric|only|fromLTRB|fromSTEB)\(([^()]*)\)');
final RegExp _literal = RegExp(r'(?<![\w.])(\d+(?:\.\d+)?)');

void main() {
  test('AC-DS-025: EdgeInsets в презентации экранов F — только токены ds.space', () {
    final List<String> violations = <String>[];
    for (final String root in _roots) {
      for (final FileSystemEntity e in Directory(root).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart') || e.path.endsWith('.g.dart')) continue;
        final String name = e.uri.pathSegments.last;
        final List<String> lines = e.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          for (final RegExpMatch m in _insets.allMatches(lines[i])) {
            final String args = m.group(1)!;
            final bool literal = _literal
                .allMatches(args)
                .any((RegExpMatch n) => double.parse(n.group(1)!) != 0); // money-double: allow — разбор отступа
            if (literal && !_allowed.contains('$name:$args')) violations.add('${e.path}:${i + 1}: ${m.group(0)}');
          }
        }
      }
    }
    expect(violations, isEmpty, reason: 'литералы отступов вместо context.space.sN (03 DS-025)');
  });
}
