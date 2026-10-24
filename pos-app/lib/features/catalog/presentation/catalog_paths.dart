// Пути экранов каталога для навигации из фичи (06 §6.4; navigation.md §3). Фича не импортирует
// `app/router` (AP-01), поэтому строит location сама — тем же форматом, что маршруты routes.dart.
// В query не попадают ПДн (N-3): `q` — только строка поиска, при перезапуске её удаляет lastLocation.

/// Построитель location маршрутов SCR-10…SCR-17, SCR-43, SCR-44, SCR-50.
abstract final class CatalogPaths {
  /// SCR-10 `/catalog?preset=&view=&sort=`.
  static String catalog({String? preset, String? view, String? sort}) =>
      _with('/catalog', <String, String?>{'preset': preset, 'view': view, 'sort': sort});

  /// SCR-11 `/catalog/search?q=&categoryId=&view=&sort=`; `categoryId` — поиск начат на SCR-12 (02 SCR-11.6:
  /// «Назад» возвращает в эту категорию).
  static String search({String? q, String? categoryId, String? view, String? sort}) =>
      _with('/catalog/search', <String, String?>{'q': q, 'categoryId': categoryId, 'view': view, 'sort': sort});

  /// SCR-12 `/catalog/c/{categoryId}?view=&sort=&f=`.
  static String category(String categoryId, {String? view, String? sort, String? f}) =>
      _with('/catalog/c/${Uri.encodeComponent(categoryId)}', <String, String?>{'view': view, 'sort': sort, 'f': f});

  /// SCR-13 `/catalog/filters?f=&q=` (маршрут-лист compact/medium); `q` — строка поиска SCR-11 (EQ-CAT-12).
  static String filters({String? f, String? q}) => _with('/catalog/filters', <String, String?>{'f': f, 'q': q});

  /// SCR-14 `/catalog/p/{productId}?variantId=`.
  static String product(String productId, {String? variantId}) =>
      _with('/catalog/p/${Uri.encodeComponent(productId)}', <String, String?>{'variantId': variantId});

  /// SCR-17 `/scan?mode=search`.
  static String scan({String mode = 'search'}) => _with('/scan', <String, String?>{'mode': mode});

  /// SCR-50 `/home?view=&sort=` — главный экран клиента-покупателя (корень каталога `customer`).
  static String home({String? view, String? sort}) => _with('/home', <String, String?>{'view': view, 'sort': sort});

  /// Корень каталога роли: `customer` — SCR-50 `/home`, staff — SCR-10 `/catalog` (navigation.md G-7).
  static String root({required bool customer}) => customer ? home() : catalog();

  /// SCR-20 «Корзина».
  static const String cart = '/cart';

  /// SCR-25 «Мои заказы» (для `customer` — только свои, `order.read.own`; UI-параметра `mine` у
  /// маршрута `OrdersRoute` пока нет — EQ-HOME-03).
  static const String myOrders = '/orders';

  /// SCR-34 «Долг клиента» (свой — `customer.self.receivables.read`).
  static String receivables(String customerId) => '/customers/${Uri.encodeComponent(customerId)}/receivables';

  /// SCR-06 «Подтверждение организации».
  static const String customerLink = '/register/customer-link';

  /// SCR-40 «Избранное».
  static const String favorites = '/favorites';

  /// SCR-41 «Профиль».
  static const String profile = '/profile';

  /// SCR-42 «Настройки».
  static const String settings = '/settings';

  /// SCR-43 «Синхронизация».
  static const String sync = '/sync';

  /// SCR-44 «Уведомления».
  static const String notifications = '/notifications';

  static String _with(String path, Map<String, String?> query) {
    final Map<String, String> q = <String, String>{
      for (final MapEntry<String, String?> e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return q.isEmpty ? path : Uri(path: path, queryParameters: q).toString();
  }
}
