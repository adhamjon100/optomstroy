// F-flutter-data-4 (04 FLOW-009.E1, AC-FLOW-009-07; 07 §11.4): предупреждение перед «Выйти» учитывает все
// неотправленные изменения корзины — строки `pending` и `dead` («не отправлено», например после
// `409 VERSION_CONFLICT`) и признак `cart_draft.dirty = 1`. Синтетические данные.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/session/session_local_data.dart';

import '../database/test_database.dart';

const String owner = '00000000-0000-4000-8000-0000000000d4';

void main() {
  configureSqliteForTests();
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> cart({required bool dirty}) => db
      .into(db.cartDraft)
      .insert(
        CartDraftCompanion.insert(
          localId: 'local-1',
          status: 'active',
          ownerUserId: owner,
          updatedAt: 1,
          dirty: Value<bool>(dirty),
        ),
      );

  Future<void> item(String state) => db
      .into(db.cartItemsDraft)
      .insert(
        CartItemsDraftCompanion.insert(
          localItemId: 'i-$state',
          localCartId: 'local-1',
          variantId: 'v-$state',
          quantityMilli: 5000,
          lineNo: 1,
          ownerUserId: owner,
          syncState: Value<String>(state),
        ),
      );

  test('строка dead («не отправлено» после 409) — предупреждение перед выходом показывается', () async {
    await cart(dirty: true);
    await item('dead');
    final PendingLocalChanges p = await SessionLocalData(db).pending(owner);
    expect(p.cartItems, 1);
    expect(p.isEmpty, isFalse);
  });

  test('cart_draft.dirty = 1 без неотправленных строк — предупреждение показывается', () async {
    await cart(dirty: true);
    await item('synced');
    final PendingLocalChanges p = await SessionLocalData(db).pending(owner);
    expect(p.cartDirty, isTrue);
    expect(p.isEmpty, isFalse);
  });

  test('всё подтверждено сервером — предупреждения нет', () async {
    await cart(dirty: false);
    await item('synced');
    expect((await SessionLocalData(db).pending(owner)).isEmpty, isTrue);
  });
}
