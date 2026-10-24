// AC-RM-C-004 п. 3 / AC-DATA-250, -252, -258, -263, -264: набор таблиц AppDatabase
// совпадает с 07 §11.2 (тест сверки имён: 0 лишних, 0 недостающих); столбцов REAL
// нет; `registration_draft` и `checkout_draft` без ПДн и платёжных данных.
// Перечень таблиц читается из docs/specification/07_DATA_MODEL.md §11.2.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';

import 'test_database.dart';

/// Имена таблиц из первой колонки таблицы 07 §11.2.
Set<String> tablesFromDataModel() {
  final file = File('../docs/specification/07_DATA_MODEL.md');
  final text = file.readAsStringSync().replaceAll('\r\n', '\n');
  final start = text.indexOf('### 11.2.');
  final end = text.indexOf('### 11.3.', start);
  expect(start, greaterThan(0), reason: '07 §11.2 не найден');
  // Первая таблица раздела: от заголовка «| Локальная таблица |» до пустой строки.
  final header = text.indexOf('| Локальная таблица |', start);
  expect(header, inExclusiveRange(start, end), reason: 'таблица 07 §11.2 не найдена');
  final section = text.substring(header, text.indexOf('\n\n', header));
  final row = RegExp(r'^\| `([a-z_]+)`', multiLine: true);
  return {for (final m in row.allMatches(section)) m.group(1)!};
}

Future<List<String>> sqliteTables(AppDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return [for (final r in rows) r.read<String>('name')];
}

Future<List<({String name, String type})>> columns(AppDatabase db, String table) async {
  final rows = await db.customSelect('PRAGMA table_info("$table")').get();
  return [for (final r in rows) (name: r.read<String>('name'), type: r.read<String>('type'))];
}

void main() {
  configureSqliteForTests();
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('07 §11.2 прочитан: 23 таблицы', () {
    final expected = tablesFromDataModel();
    expect(expected, hasLength(23));
    expect(
      expected,
      containsAll([
        'cart_draft',
        'cart_items_draft',
        'outbox_actions',
        'registration_draft',
        'checkout_draft',
        'app_meta',
      ]),
    );
  });

  test('набор таблиц AppDatabase == 07 §11.2 (0 лишних, 0 недостающих)', () async {
    final expected = tablesFromDataModel();
    final declared = {for (final t in db.allTables) t.actualTableName};
    expect(declared.difference(expected), isEmpty, reason: 'лишние таблицы');
    expect(expected.difference(declared), isEmpty, reason: 'недостающие таблицы');
    expect((await sqliteTables(db)).toSet(), expected, reason: 'фактическая схема SQLite');
  });

  test('запрещённых таблиц нет (ядро §18.2 п.1, DATA-258, DATA-263, DATA-264)', () async {
    final actual = await sqliteTables(db);
    for (final forbidden in [
      'cart_drafts',
      'pending_operations',
      'receivables_cache',
      'customers_cache',
      'orders',
      'payments',
      'receivables',
      'transactions',
      'sessions',
      'audit_logs',
    ]) {
      expect(actual, isNot(contains(forbidden)));
    }
  });

  test('DATA-252: столбцов REAL нет; деньги и количества — INTEGER', () async {
    for (final table in await sqliteTables(db)) {
      for (final c in await columns(db, table)) {
        expect(c.type.toUpperCase(), isNot(anyOf('REAL', 'FLOAT', 'DOUBLE', 'NUMERIC')), reason: '$table.${c.name}');
        if (c.name.endsWith('_tyiyn') || c.name.endsWith('_milli') || c.name.endsWith('_at')) {
          expect(c.type.toUpperCase(), 'INTEGER', reason: '$table.${c.name}');
        }
      }
    }
  });

  test('registration_draft и checkout_draft без ПДн и платёжных данных', () async {
    final forbidden = RegExp(
      r'name|phone|address|birth|amount|sum|total|tyiyn|qr|card|requisite|pin|token|password|otp',
      caseSensitive: false,
    );
    final registration = [for (final c in await columns(db, 'registration_draft')) c.name];
    expect(registration, ['key', 'value_json']);
    final checkout = [for (final c in await columns(db, 'checkout_draft')) c.name];
    expect(checkout, [
      'local_cart_id',
      'step',
      'customer_id',
      'delivery_method',
      'receiver_kind',
      'payment_method',
      'order_idempotency_key',
      'submitted_at',
      'updated_at',
    ]);
    for (final c in checkout.where((c) => c != 'order_idempotency_key')) {
      expect(forbidden.hasMatch(c), isFalse, reason: 'checkout_draft.$c');
    }
  });

  test('секреты не хранятся в drift: нет столбцов токенов, PIN, долга', () async {
    final secret = RegExp(r'refresh|access_token|device_id|pin_hash|biometric|balance|overdue|credit|has_debt');
    for (final table in await sqliteTables(db)) {
      for (final c in await columns(db, table)) {
        expect(secret.hasMatch(c.name), isFalse, reason: '$table.${c.name}');
      }
    }
  });

  test('ключевые столбцы 07 §11.2 присутствуют', () async {
    Future<List<String>> names(String t) async => [for (final c in await columns(db, t)) c.name];
    expect(
      await names('outbox_actions'),
      containsAll(['idempotency_key', 'owner_user_id', 'status', 'attempts', 'next_attempt_at']),
    );
    expect(await names('cart_draft'), containsAll(['local_id', 'owner_user_id', 'base_row_version', 'dirty']));
    expect(await names('cart_items_draft'), containsAll(['owner_user_id', 'sync_state', 'quantity_milli']));
    expect(await names('stock_balances'), containsAll(['stock_level', 'available_milli', 'snapshot_at']));
    expect(await names('sync_meta'), containsAll(['server_cursor', 'as_of', 'stale_after_sec']));
    expect(await names('prices'), containsAll(['price_tyiyn', 'price_list_id', 'packaging_id']));
  });

  test('CHECK-ограничения: неизвестный тип outbox и статус отклоняются', () async {
    Future<void> insert(String type) => db.customStatement(
      'INSERT INTO outbox_actions (type, payload_json, idempotency_key, owner_user_id, created_at) '
      "VALUES ('$type', '{}', '$type-key', 'u1', 0)",
    );
    await insert('favorite.add');
    await expectLater(insert('order.create'), throwsA(isA<SqliteException>()));
    final row = await db.select(db.outboxActions).getSingle();
    expect(row.status, 'pending');
    expect(row.attempts, 0);
  });

  test('app_meta: schema_version записывается при создании; DAO read/write/remove', () async {
    expect(await db.appMetaDao.read(AppMetaDao.schemaVersionKey), '${AppDatabase.latestSchemaVersion}');
    await db.appMetaDao.write(AppMetaDao.minAppVersionSeenKey, '1.2.0');
    await db.appMetaDao.write(AppMetaDao.minAppVersionSeenKey, '1.3.0');
    expect(await db.appMetaDao.read(AppMetaDao.minAppVersionSeenKey), '1.3.0');
    await db.appMetaDao.remove(AppMetaDao.minAppVersionSeenKey);
    expect(await db.appMetaDao.read(AppMetaDao.minAppVersionSeenKey), isNull);
  });

  test('имя файла пользователя pos_<user_id>.db; не-UUID отклоняется', () {
    expect(
      AppDatabase.fileNameFor('0192F3A1-6C3E-7A1B-9F00-2B7C1D3E4F55'),
      'pos_0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55.db',
    );
    expect(() => AppDatabase.fileNameFor('../evil'), throwsArgumentError);
  });

  test('upsert по составному ключу с NULL: prices работает через Companion', () async {
    await db
        .into(db.localPrices)
        .insert(LocalPricesCompanion.insert(variantId: 'v1', priceListId: 'p1', priceTyiyn: 235000, serverSyncedAt: 1));
    final row = await db.select(db.localPrices).getSingle();
    expect(row.priceTyiyn, 235000);
    expect(row.packagingId, isNull);
  });
}
