// Локальные настройки экранов каталога (02 SCR-10.4.C, SCR-10.11): вид по классу окна, сортировка,
// свёрнутый сайдбар. ПДн нет. EQ-CAT-05 (перенос этапа E): значения — «на пользователя», только drift `settings`
// БД пользователя через порт domain `CatalogUserSettingsStore`, область `scope=user` — очищаются при выходе,
// `SESSION_REVOKED` и смене пользователя (`SessionLocalData.clearOnSessionEnd`, 07 §11.4). `shared_preferences`
// (настройка «на устройство») не используется; без БД (до входа, тесты без привязок) — только память процесса.
// Ошибки хранилища не ломают экран: значение по умолчанию.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/design_system/components/view_mode_segmented.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_user_settings_store.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';

abstract interface class CatalogPrefs {
  Future<ProductViewMode?> viewMode(WindowClass windowClass);

  Future<void> setViewMode(WindowClass windowClass, ProductViewMode mode);

  /// Сортировка каталога ([search] = `false`) или поиска.
  Future<CatalogSort?> sort({required bool search});

  Future<void> setSort(CatalogSort sort, {required bool search});

  Future<bool?> sidebarCollapsed();

  Future<void> setSidebarCollapsed(bool value);
}

/// Значения по умолчанию (02 SCR-10.4.C, SCR-11 UI-11-008; 03 §9.26).
abstract final class CatalogDefaults {
  /// compact — список; medium/expanded/large — сетка.
  static ProductViewMode viewFor(WindowClass wc) =>
      wc == WindowClass.compact ? ProductViewMode.list : ProductViewMode.grid;

  /// Каталог — «По названию А–Я» [ТИПОВО].
  static const CatalogSort catalogSort = CatalogSort.nameAsc;

  /// Поиск — «По релевантности».
  static const CatalogSort searchSort = CatalogSort.relevanceDesc;
}

/// Хранилище в памяти (тесты, витрина).
final class InMemoryCatalogPrefs implements CatalogPrefs {
  final Map<String, Object> _values = <String, Object>{};

  @override
  Future<ProductViewMode?> viewMode(WindowClass windowClass) async =>
      ProductViewMode.tryParse(_values['view.${windowClass.name}'] as String?);

  @override
  Future<void> setViewMode(WindowClass windowClass, ProductViewMode mode) async =>
      _values['view.${windowClass.name}'] = mode.value;

  @override
  Future<CatalogSort?> sort({required bool search}) async =>
      CatalogSort.tryParse(_values[search ? 'sort.search' : 'sort.catalog'] as String?);

  @override
  Future<void> setSort(CatalogSort sort, {required bool search}) async =>
      _values[search ? 'sort.search' : 'sort.catalog'] = sort.value;

  @override
  Future<bool?> sidebarCollapsed() async => _values['sidebar.collapsed'] as bool?;

  @override
  Future<void> setSidebarCollapsed(bool value) async => _values['sidebar.collapsed'] = value;
}

/// Настройки в drift `settings` БД пользователя, `scope=user` (EQ-CAT-05: на пользователя, очистка при выходе).
final class UserCatalogPrefs implements CatalogPrefs {
  UserCatalogPrefs(this._store);

  final CatalogUserSettingsStore _store;

  /// Область строк вида, сортировки и сайдбара (07 §11.2 `settings.scope`).
  static const CatalogSettingScope scope = CatalogSettingScope.user;

  Future<void> _write(String key, String value) => _store.write(key, value, scope: scope);

  @override
  Future<ProductViewMode?> viewMode(WindowClass windowClass) async =>
      ProductViewMode.tryParse(await _store.read(CatalogSettingKeys.viewMode(windowClass.name)));

  @override
  Future<void> setViewMode(WindowClass windowClass, ProductViewMode mode) =>
      _write(CatalogSettingKeys.viewMode(windowClass.name), mode.value);

  @override
  Future<CatalogSort?> sort({required bool search}) async =>
      CatalogSort.tryParse(await _store.read(CatalogSettingKeys.sort(search: search)));

  @override
  Future<void> setSort(CatalogSort sort, {required bool search}) =>
      _write(CatalogSettingKeys.sort(search: search), sort.value);

  @override
  Future<bool?> sidebarCollapsed() async => switch (await _store.read(CatalogSettingKeys.sidebarCollapsed)) {
    'true' => true,
    'false' => false,
    _ => null,
  };

  @override
  Future<void> setSidebarCollapsed(bool value) => _write(CatalogSettingKeys.sidebarCollapsed, '$value');
}

/// Настройки экранов каталога: после входа — БД пользователя ([catalogUserSettingsStoreProvider], `scope=user`),
/// иначе — память процесса (на диск «на устройство» не пишется); в тестах — `overrideWithValue(InMemoryCatalogPrefs())`.
/// Смена пользователя меняет хранилище — провайдер пересоздаётся и читает файл нового пользователя.
final catalogPrefsProvider = Provider<CatalogPrefs>((ref) {
  final CatalogUserSettingsStore? store = ref.watch(catalogUserSettingsStoreProvider);
  return store == null ? InMemoryCatalogPrefs() : UserCatalogPrefs(store);
});

/// История запросов поиска (UI-11-011): drift `settings`, ключ `search_history`, scope `user` в БД текущего
/// пользователя (EQ-CAT-06). Только текущий пользователь: `build()` зависит от [catalogSessionUserProvider] и
/// [catalogUserSettingsStoreProvider] — смена пользователя пересоздаёт состояние и читает его файл; строка
/// `scope=user` удаляется при выходе (`POST /auth/logout`), `SESSION_REVOKED` и смене пользователя
/// (`SessionLocalData.clearOnSessionEnd`, 07 §11.4; 02 SCR-10.4.A, AC-UI-11-014). Без БД — только память процесса.
/// Строки, похожие на телефон, не сохраняются (11 PRIV-002, SEC-098) — ни в памяти, ни на диске.
final searchHistoryProvider = NotifierProvider<SearchHistory, List<String>>(SearchHistory.new);

final class SearchHistory extends Notifier<List<String>> {
  static const int limit = 5;

  CatalogUserSettingsStore? _store;

  /// Изменения до окончания чтения из БД (запрос введён сразу после открытия экрана).
  bool _touched = false;

  @override
  List<String> build() {
    ref.watch(catalogSessionUserProvider);
    final CatalogUserSettingsStore? store = ref.watch(catalogUserSettingsStoreProvider);
    _store = store;
    _touched = false;
    if (store != null) unawaited(_load(store));
    return const <String>[];
  }

  Future<void> _load(CatalogUserSettingsStore store) async {
    final List<String> saved = decode(await store.read(CatalogSettingKeys.searchHistory));
    if (!ref.mounted || !identical(_store, store) || saved.isEmpty) return;
    // Запрос, введённый до окончания чтения, — первым; дубликаты и строки-телефоны отбрасываются.
    state = _merge(_touched ? state : const <String>[], saved);
  }

  /// JSON-массив строк → история (повреждённое значение — пусто).
  static List<String> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final Object? j = jsonDecode(raw);
      if (j is! List) return const <String>[];
      return _merge(const <String>[], <String>[
        for (final Object? v in j)
          if (v is String) v,
      ]);
    } on FormatException {
      return const <String>[];
    }
  }

  static List<String> _merge(List<String> head, List<String> tail) {
    final List<String> out = <String>[];
    for (final String q in <String>[...head, ...tail]) {
      final String v = q.trim();
      if (v.isEmpty || isPhoneLike(v) || out.contains(v)) continue;
      out.add(v);
      if (out.length == limit) break;
    }
    return List<String>.unmodifiable(out);
  }

  void _persist() {
    final CatalogUserSettingsStore? store = _store;
    if (store == null) return;
    final List<String> value = state;
    unawaited(
      value.isEmpty
          ? store.remove(CatalogSettingKeys.searchHistory)
          : store.write(CatalogSettingKeys.searchHistory, jsonEncode(value), scope: CatalogSettingScope.user),
    );
  }

  /// Похоже на телефон: содержит `+996` или после удаления пробелов, `+ - ( )` — только цифры, ≥ 9.
  static bool isPhoneLike(String q) {
    if (q.contains('+996')) {
      return true;
    }
    final String stripped = q.replaceAll(RegExp(r'[\s+\-()]'), '');
    return stripped.length >= 9 && RegExp(r'^\d+$').hasMatch(stripped);
  }

  void add(String query) {
    final String q = query.trim();
    if (q.isEmpty || isPhoneLike(q)) {
      return;
    }
    _touched = true;
    state = <String>[q, ...state.where((String s) => s != q)].take(limit).toList(growable: false);
    _persist();
  }

  void remove(String query) {
    _touched = true;
    state = state.where((String s) => s != query).toList(growable: false);
    _persist();
  }

  void clear() {
    _touched = true;
    state = const <String>[];
    _persist();
  }
}

/// Запись настройки без ожидания (ошибки уже поглощены реализацией).
void savePref(Future<void> pending) => unawaited(pending);
