// БД пользователя корня (`userDatabase`, 07 §11.1 п.2): не-UUID — `null` с предупреждением; проверка идёт до
// открытия, чтобы прочие ArgumentError drift (например, сборка для браузера без web-опций) не глушились молча, а
// писались в журнал как SEVERE. Открытие по UUID — test/core/database/app_database_web_test.dart (опции drift).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/di/core_providers.dart';

void main() {
  test('не-UUID — null и предупреждение (не SEVERE); выход — null', () async {
    final List<LogRecord> records = <LogRecord>[];
    final StreamSubscription<LogRecord> sub = Logger.root.onRecord.listen(records.add);
    addTearDown(sub.cancel);
    final ProviderContainer container = ProviderContainer(overrides: [appDatabaseProvider.overrideWith(userDatabase)]);
    addTearDown(container.dispose);

    expect(container.read(appDatabaseProvider), isNull, reason: 'до входа');
    container.read(sessionUserIdProvider.notifier).set('../evil');
    expect(container.read(appDatabaseProvider), isNull);
    expect(
      records.where((LogRecord r) => r.level == Level.WARNING).map((LogRecord r) => r.message),
      contains('userDatabase: идентификатор пользователя не UUID — локальная БД не открыта'),
    );
    expect(records.where((LogRecord r) => r.level >= Level.SEVERE), isEmpty);

    container.read(sessionUserIdProvider.notifier).set(null);
    expect(container.read(appDatabaseProvider), isNull, reason: 'выход');
  });
}
