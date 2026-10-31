// Открытие БД пользователя (07 §11.1 п.2) с web-опциями drift: в браузере (веб-демо) `driftDatabase` без `web`
// бросает ArgumentError, и БД пользователя молча не открывалась бы (нет кэша каталога, черновика корзины, outbox).
// Опции — `sqlite3.wasm` и `drift_worker.js` рядом с `index.html` сайта; выбор хранилища drift — в журнал.
import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection, QueryExecutor;
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/database/app_database.dart';

void main() {
  const String userId = '0192F3A1-6C3E-7A1B-9F00-2B7C1D3E4F55';

  test('isUserId: UUID — да; путь, пустая строка, обрезанный UUID — нет', () {
    expect(AppDatabase.isUserId(userId), isTrue);
    expect(AppDatabase.isUserId(userId.toLowerCase()), isTrue);
    for (final String bad in <String>['', '../evil', 'pos_1', userId.substring(1)]) {
      expect(AppDatabase.isUserId(bad), isFalse, reason: bad);
    }
  });

  test('web-опции: sqlite3.wasm и drift_worker.js относительно <base href>, свой обработчик результата', () {
    final DriftWebOptions web = AppDatabase.webOptions();
    expect(web.sqlite3Wasm, Uri.parse('sqlite3.wasm'));
    expect(web.driftWorker, Uri.parse('drift_worker.js'));
    expect(web.sqlite3Wasm.hasScheme, isFalse, reason: 'тот же сайт, что и страница');
    expect(web.onResult, isNotNull);
    expect(web.initializeDatabase, isNull);
  });

  test('openUserDatabase: файл pos_<uuid>.db, переданы и native-, и web-опции; не-UUID — ArgumentError', () {
    final QueryExecutor executor = AppDatabase.openUserDatabase(
      userId,
      open: ({required String name, DriftWebOptions? web, DriftNativeOptions? native}) => _Capture(name, web, native),
    );
    final _Capture c = executor as _Capture;
    expect(c.name, 'pos_0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55.db');
    expect(c.web?.sqlite3Wasm.toString(), AppDatabase.webSqlite3Wasm);
    expect(c.web?.driftWorker.toString(), AppDatabase.webDriftWorker);
    expect(c.native?.databasePath, isNotNull);
    expect(() => AppDatabase.openUserDatabase('../evil'), throwsArgumentError);
  });

  test('журнал выбора хранилища: OPFS — info; IndexedDB без гарантий и память — warning с недостающим', () async {
    final List<LogRecord> records = <LogRecord>[];
    final StreamSubscription<LogRecord> sub = Logger.root.onRecord.listen(records.add);
    addTearDown(sub.cancel);
    final NativeDatabase memory = NativeDatabase.memory();
    addTearDown(memory.close);
    final DatabaseConnection connection = DatabaseConnection(memory);

    AppDatabase.logWebResult(
      WasmDatabaseResult(connection, WasmStorageImplementation.opfsLocks, const <MissingBrowserFeature>{}),
    );
    AppDatabase.logWebResult(
      WasmDatabaseResult(connection, WasmStorageImplementation.unsafeIndexedDb, const <MissingBrowserFeature>{
        MissingBrowserFeature.sharedArrayBuffers,
      }),
    );
    AppDatabase.logWebResult(
      WasmDatabaseResult(connection, WasmStorageImplementation.inMemory, const <MissingBrowserFeature>{}),
    );

    final List<LogRecord> db = records.where((LogRecord r) => r.loggerName == 'database').toList();
    expect(db.map((LogRecord r) => r.level).toList(), <Level>[Level.INFO, Level.WARNING, Level.WARNING]);
    expect(db[0].message, 'drift web: opfsLocks');
    expect(db[1].message, 'drift web: unsafeIndexedDb (нет: sharedArrayBuffers)');
    expect(db[2].message, 'drift web: inMemory');
  });
}

/// Исполнитель-заглушка: запоминает аргументы `driftDatabase`.
final class _Capture implements QueryExecutor {
  _Capture(this.name, this.web, this.native);

  final String name;
  final DriftWebOptions? web;
  final DriftNativeOptions? native;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
