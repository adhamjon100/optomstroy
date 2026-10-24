// Сериализация фильтров каталога в query `f` (navigation.md §3: «сериализованные фильтры»; формат
// в ТЗ не задан — EQ-CAT-01). `f` — строка query-параметров, закодированная как одно значение:
//   c=<categoryId>  sub=0  wh=<warehouseId>  stock=1  pmin=1500.00  pmax=4200.00
//   brand=<b> (повторяется)  attr.<ключ>=<значение>  fav=1  img=1
// Вид цены (`priceListId`) в `f` не попадает: его определяет сервер (CUST-021, D-23).
// ПДн в фильтрах нет (navigation.md N-3).
import 'package:optomstroy/core/utils/amount_exception.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';

abstract final class CatalogFilterCodec {
  static const String _attrPrefix = 'attr.';

  /// `null` — фильтров нет (параметр `f` не пишется).
  static String? encode(CatalogFilter f, {bool includeCategory = true}) {
    final Map<String, List<String>> q = <String, List<String>>{
      if (includeCategory && f.categoryId != null) 'c': <String>[f.categoryId!],
      if (!f.includeSubcategories) 'sub': <String>['0'],
      if (f.warehouseId != null) 'wh': <String>[f.warehouseId!],
      if (f.inStock == true) 'stock': <String>['1'],
      if (f.priceMin != null) 'pmin': <String>[f.priceMin!.toApiString()],
      if (f.priceMax != null) 'pmax': <String>[f.priceMax!.toApiString()],
      if (f.brands.isNotEmpty) 'brand': f.brands,
      for (final MapEntry<String, String> a in f.attrs.entries) '$_attrPrefix${a.key}': <String>[a.value],
      if (f.favorite == true) 'fav': <String>['1'],
      if (f.hasImage == true) 'img': <String>['1'],
    };
    if (q.isEmpty) {
      return null;
    }
    return Uri(queryParameters: q).query;
  }

  /// Разбор `f`; неизвестные и некорректные значения отбрасываются (deep link не ломает экран).
  static CatalogFilter decode(String? raw, {String? categoryId}) {
    if (raw == null || raw.isEmpty) {
      return CatalogFilter(categoryId: categoryId);
    }
    final Map<String, List<String>> q;
    try {
      q = Uri(query: raw).queryParametersAll;
    } on FormatException {
      return CatalogFilter(categoryId: categoryId);
    }
    String? one(String k) {
      final List<String>? v = q[k];
      return v == null || v.isEmpty || v.first.isEmpty ? null : v.first;
    }

    Money? money(String k) {
      final String? v = one(k);
      if (v == null) {
        return null;
      }
      try {
        return Money.fromString(v);
      } on AmountException {
        return null;
      }
    }

    final Map<String, String> attrs = <String, String>{
      for (final MapEntry<String, List<String>> e in q.entries)
        if (e.key.startsWith(_attrPrefix) && e.key.length > _attrPrefix.length && e.value.isNotEmpty)
          e.key.substring(_attrPrefix.length): e.value.first,
    };
    return CatalogFilter(
      categoryId: categoryId ?? one('c'),
      includeSubcategories: one('sub') != '0',
      warehouseId: one('wh'),
      inStock: one('stock') == '1' ? true : null,
      priceMin: money('pmin'),
      priceMax: money('pmax'),
      brands: <String>[...?q['brand']?.where((String b) => b.isNotEmpty)],
      attrs: attrs.length > CatalogFilter.maxAttrs
          ? Map<String, String>.fromEntries(attrs.entries.take(CatalogFilter.maxAttrs))
          : attrs,
      favorite: one('fav') == '1' ? true : null,
      hasImage: one('img') == '1' ? true : null,
    );
  }

  /// Тот же фильтр без пользовательских условий (категория и склад сохраняются) — «Сбросить все».
  static CatalogFilter cleared(CatalogFilter f) =>
      CatalogFilter(categoryId: f.categoryId, includeSubcategories: f.includeSubcategories, warehouseId: f.warehouseId);

  /// Равенство фильтров по смыслу (для ключей провайдеров и «повторный выбор — без запроса»).
  static bool same(CatalogFilter a, CatalogFilter b) =>
      a.categoryId == b.categoryId && encode(a) == encode(b) && a.priceListId == b.priceListId;
}

/// Явная копия фильтра: в `CatalogFilter.copyWith` нельзя сбросить поле в `null`.
CatalogFilter rebuildFilter(
  CatalogFilter f, {
  Object? categoryId = _keep,
  bool? includeSubcategories,
  Object? warehouseId = _keep,
  Object? inStock = _keep,
  Object? priceMin = _keep,
  Object? priceMax = _keep,
  List<String>? brands,
  Map<String, String>? attrs,
  Object? favorite = _keep,
  Object? hasImage = _keep,
}) => CatalogFilter(
  categoryId: identical(categoryId, _keep) ? f.categoryId : categoryId as String?,
  includeSubcategories: includeSubcategories ?? f.includeSubcategories,
  warehouseId: identical(warehouseId, _keep) ? f.warehouseId : warehouseId as String?,
  priceListId: f.priceListId,
  inStock: identical(inStock, _keep) ? f.inStock : inStock as bool?,
  priceMin: identical(priceMin, _keep) ? f.priceMin : priceMin as Money?,
  priceMax: identical(priceMax, _keep) ? f.priceMax : priceMax as Money?,
  brands: brands ?? f.brands,
  attrs: attrs ?? f.attrs,
  favorite: identical(favorite, _keep) ? f.favorite : favorite as bool?,
  hasImage: identical(hasImage, _keep) ? f.hasImage : hasImage as bool?,
);

const Object _keep = Object();
