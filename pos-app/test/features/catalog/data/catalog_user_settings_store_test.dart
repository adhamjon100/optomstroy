// EQ-CAT-05, EQ-CAT-06, E-security-3: настройки экранов каталога и история поиска — drift `settings` БД
// пользователя. История (scope `user`) переживает перезапуск, очищается при выходе / `SESSION_REVOKED` /
// смене пользователя (`SessionLocalData.clearOnSessionEnd`), строки-телефоны не сохраняются. EQ-CAT-05 (перенос в F):
// вид, сортировка и сайдбар — тоже `scope=user` (на пользователя), переживают перезапуск и очищаются при выходе;
// без БД — только память процесса (`shared_preferences` не используется).
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/data/local/drift_catalog_user_settings_store.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_user_settings_store.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';

void main() {
  late AppDatabase db;
  late DriftCatalogUserSettingsStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = DriftCatalogUserSettingsStore(db, FixedClock(DateTime.utc(2026, 10, 22, 9)));
  });
  tearDown(() => db.close());

  ProviderContainer container({CatalogUserSettingsStore? withStore, String? user = 'u-1'}) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        catalogUserSettingsStoreProvider.overrideWithValue(withStore),
        catalogSessionUserProvider.overrideWithValue(user),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<List<String>> loaded(ProviderContainer c) async {
    c.read(searchHistoryProvider);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return c.read(searchHistoryProvider);
  }

  test('история поиска переживает перезапуск, строки-телефоны не сохраняются (AC-UI-11-014)', () async {
    final ProviderContainer first = container(withStore: store);
    await loaded(first);
    first.read(searchHistoryProvider.notifier)
      ..add('F4252-CR')
      ..add('+996 555 123 456')
      ..add('0555123456')
      ..add('смеситель');
    await Future<void>.delayed(Duration.zero);
    expect(first.read(searchHistoryProvider), <String>['смеситель', 'F4252-CR']);

    final SettingRow row = await (db.select(
      db.localSettings,
    )..where(($LocalSettingsTable t) => t.key.equals(CatalogSettingKeys.searchHistory))).getSingle();
    expect(row.scope, 'user');
    expect(row.valueJson, isNot(contains('555')));

    // «Перезапуск»: новый контейнер над тем же файлом пользователя.
    expect(await loaded(container(withStore: store)), <String>['смеситель', 'F4252-CR']);
  });

  test('EQ-CAT-05: вид и сортировка — drift scope=user; переживают перезапуск; выход / SESSION_REVOKED / смена '
      'пользователя — история, вид и сортировка удалены', () async {
    final ProviderContainer c = container(withStore: store);
    await loaded(c);
    c.read(searchHistoryProvider.notifier).add('кран');
    final CatalogPrefs prefs = c.read(catalogPrefsProvider);
    expect(prefs, isA<UserCatalogPrefs>());
    await prefs.setViewMode(WindowClass.expanded, ProductViewMode.compact);
    await prefs.setViewMode(WindowClass.compact, ProductViewMode.grid);
    await prefs.setSort(CatalogSort.priceAsc, search: false);
    await prefs.setSort(CatalogSort.nameAsc, search: true);
    await prefs.setSidebarCollapsed(true);
    await Future<void>.delayed(Duration.zero);

    final List<SettingRow> rows = await db.select(db.localSettings).get();
    expect(
      rows.map((SettingRow r) => r.key),
      containsAll(<String>[
        CatalogSettingKeys.viewMode('expanded'),
        CatalogSettingKeys.viewMode('compact'),
        CatalogSettingKeys.sort(search: false),
        CatalogSettingKeys.sort(search: true),
        CatalogSettingKeys.sidebarCollapsed,
      ]),
    );
    expect(rows.map((SettingRow r) => r.scope).toSet(), <String>{'user'}, reason: 'на пользователя, не на устройство');

    // «Перезапуск» того же пользователя: значения читаются из его файла БД, по классу окна раздельно.
    final CatalogPrefs restarted = container(withStore: store).read(catalogPrefsProvider);
    expect(await restarted.viewMode(WindowClass.expanded), ProductViewMode.compact);
    expect(await restarted.viewMode(WindowClass.compact), ProductViewMode.grid);
    expect(await restarted.viewMode(WindowClass.medium), isNull);
    expect(await restarted.sort(search: false), CatalogSort.priceAsc);
    expect(await restarted.sort(search: true), CatalogSort.nameAsc);
    expect(await restarted.sidebarCollapsed(), isTrue);

    await SessionLocalData(db).clearOnSessionEnd('u-1');

    expect(await loaded(container(withStore: store)), isEmpty);
    final CatalogPrefs again = UserCatalogPrefs(store);
    expect(await again.viewMode(WindowClass.expanded), isNull, reason: 'после выхода — значение по умолчанию');
    expect(await again.sort(search: false), isNull);
    expect(await again.sidebarCollapsed(), isNull);
    expect(await db.select(db.localSettings).get(), isEmpty);
  });

  test('EQ-CAT-05: настройки одного пользователя не видны другому (файл БД пользователя)', () async {
    final AppDatabase other = AppDatabase(NativeDatabase.memory());
    addTearDown(other.close);
    final DriftCatalogUserSettingsStore otherStore = DriftCatalogUserSettingsStore(
      other,
      FixedClock(DateTime.utc(2026, 10, 22, 9)),
    );
    await UserCatalogPrefs(store).setViewMode(WindowClass.expanded, ProductViewMode.list);
    final CatalogPrefs second = container(withStore: otherStore, user: 'u-2').read(catalogPrefsProvider);
    expect(await second.viewMode(WindowClass.expanded), isNull);
  });

  test('без БД пользователя — только память; удаление и очистка истории', () async {
    final ProviderContainer c = container();
    expect(await loaded(c), isEmpty);
    c.read(searchHistoryProvider.notifier)
      ..add('a1')
      ..add('b2')
      ..remove('a1');
    expect(c.read(searchHistoryProvider), <String>['b2']);
    // EQ-CAT-05: без БД пользователя — только память процесса (не `shared_preferences` на устройство).
    final CatalogPrefs memory = c.read(catalogPrefsProvider);
    expect(memory, isA<InMemoryCatalogPrefs>());
    await memory.setViewMode(WindowClass.compact, ProductViewMode.grid);
    expect(await memory.viewMode(WindowClass.compact), ProductViewMode.grid);
    expect(await container().read(catalogPrefsProvider).viewMode(WindowClass.compact), isNull);

    final ProviderContainer persisted = container(withStore: store);
    await loaded(persisted);
    persisted.read(searchHistoryProvider.notifier)
      ..add('x1')
      ..clear();
    await Future<void>.delayed(Duration.zero);
    expect(await store.read(CatalogSettingKeys.searchHistory), isNull);
  });

  test('закрытая БД (смена пользователя во время чтения) — значение по умолчанию без исключения', () async {
    await db.close();
    expect(await store.read(CatalogSettingKeys.searchHistory), isNull);
    await store.write('k', 'v', scope: CatalogSettingScope.device);
    expect(SearchHistory.decode('not json'), isEmpty);
  });
}
