// Порт локальных настроек экранов каталога в БД текущего пользователя (02 SCR-10.4.A, SCR-10.4.C, UI-11-011;
// 07 §11.2 `settings`; EQ-CAT-05, EQ-CAT-06). Реализация — drift `settings` (features/catalog/data/local),
// подключает `catalogOfflineFirstBindings`. Файл БД принадлежит пользователю (`pos_<user_id>.db`, 07 §11.1 п. 2),
// поэтому значения — «на пользователя»; область строки задаёт [CatalogSettingScope].
//
// Значения — строки (JSON кодирует presentation): порт не знает типов design_system (FL-01).

/// Область строки `settings.scope` (07 §11.2).
enum CatalogSettingScope {
  /// `user` — очищается при выходе, `SESSION_REVOKED` и смене пользователя (07 §11.4): история поиска.
  user('user'),

  /// `device` — переживает выход того же пользователя (вид, сортировка, свёрнутый сайдбар).
  device('device');

  const CatalogSettingScope(this.value);

  /// Значение столбца `settings.scope`.
  final String value;
}

/// Хранилище настроек каталога текущего пользователя.
abstract interface class CatalogUserSettingsStore {
  /// Значение по [key]; `null` — нет строки или чтение не удалось (БД закрыта при смене пользователя).
  Future<String?> read(String key);

  /// Записать [value] по [key] в области [scope]. Ошибки записи поглощаются (настройка не критична).
  Future<void> write(String key, String value, {required CatalogSettingScope scope});

  /// Удалить строку [key].
  Future<void> remove(String key);
}

/// Ключи строк `settings` экранов каталога (02 §14 замечание 10, 30: `catalog_view_mode`, `sidebar_collapsed`,
/// `search_history` `[НОВОЕ ИМЯ]`).
abstract final class CatalogSettingKeys {
  /// История запросов поиска (UI-11-011), JSON-массив строк, scope `user`.
  static const String searchHistory = 'search_history';

  /// Вид списка по классу окна: `catalog_view_mode.<windowClass>`, scope `device`.
  static String viewMode(String windowClass) => 'catalog_view_mode.$windowClass';

  /// Сортировка каталога / поиска: `catalog_sort.catalog|search`, scope `device`.
  static String sort({required bool search}) => 'catalog_sort.${search ? 'search' : 'catalog'}';

  /// Свёрнутый сайдбар SCR-10 (expanded), scope `device`.
  static const String sidebarCollapsed = 'sidebar_collapsed';
}
