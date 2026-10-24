// Чтение JSON для ручных DTO (ADR-085) этапа F и далее: корзина, заказы, платежи, клиенты, уведомления.
// Обязательное поле без значения или неверного типа — [DtoFormatException] (ответ не по контракту →
// `ErrorMapper.guard` превращает его в `UnknownFailure`); необязательное — `null` (совместимость вперёд).
// Деньги и количества остаются строками контракта (`MoneyAmount`, `QuantityValue`) до маппера — в тыйыны и
// milli-units их переводят `Money.fromString` / `Qty.fromString` (D-19; double запрещён — MNY-002).
//
// Каталог этапа E держит собственную копию (`features/catalog/data/dto/json_read.dart`), этот файл — общий
// для фич, которым FL-06 не разрешает импортировать data каталога.
import 'package:optomstroy/core/network/models/money_dto.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Ответ не соответствует контракту (нет обязательного поля / неверный тип / неверный формат значения).
final class DtoFormatException implements Exception {
  const DtoFormatException(this.field);

  /// Имя поля контракта (без значения — ПДн в исключение не попадают).
  final String field;

  @override
  String toString() => 'DtoFormatException($field)';
}

/// Объект JSON.
typedef JsonMap = Map<String, dynamic>;

/// Тело ответа как объект JSON.
JsonMap jsonObject(Object? data, [String field = 'body']) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return data.cast<String, dynamic>();
  throw DtoFormatException(field);
}

/// Обязательное поле типа [T].
T jReq<T>(JsonMap json, String key) {
  final Object? v = json[key];
  if (v is T) return v;
  throw DtoFormatException(key);
}

/// Необязательное поле типа [T] (`null` — нет или иной тип).
T? jOpt<T>(JsonMap json, String key) {
  final Object? v = json[key];
  return v is T ? v : null;
}

/// Целое: JSON-числа приходят как `int` (на вебе — `num`).
int? jInt(JsonMap json, String key) {
  final Object? v = json[key];
  if (v is int) return v;
  if (v is num && v == v.roundToDouble()) return v.toInt(); // money-double: allow — JSON-число → int (не деньги)
  return null;
}

/// Обязательное целое.
int jReqInt(JsonMap json, String key) => jInt(json, key) ?? (throw DtoFormatException(key));

/// Необязательный `bool`.
bool? jBool(JsonMap json, String key) => jOpt<bool>(json, key);

/// Дата-время ISO-8601 (UTC сохраняется как пришло).
DateTime? jDate(JsonMap json, String key) {
  final String? v = jOpt<String>(json, key);
  return v == null ? null : DateTime.tryParse(v);
}

/// Обязательная дата-время.
DateTime jReqDate(JsonMap json, String key) => jDate(json, key) ?? (throw DtoFormatException(key));

/// Вложенный объект (`null` — нет или не объект).
JsonMap? jObject(JsonMap json, String key) {
  final Object? v = json[key];
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.cast<String, dynamic>();
  return null;
}

/// Обязательный вложенный объект.
JsonMap jReqObject(JsonMap json, String key) => jObject(json, key) ?? (throw DtoFormatException(key));

/// Список объектов; элемент — не объект → ошибка формата.
List<T> jObjects<T>(JsonMap json, String key, T Function(JsonMap item) parse, {bool required = false}) {
  final Object? v = json[key];
  if (v == null) {
    if (required) throw DtoFormatException(key);
    return <T>[];
  }
  if (v is! List) throw DtoFormatException(key);
  return <T>[for (final Object? item in v) parse(jsonObject(item, key))];
}

/// Список строк (`null` → пустой).
List<String> jStrings(JsonMap json, String key, {bool required = false}) {
  final Object? v = json[key];
  if (v == null) {
    if (required) throw DtoFormatException(key);
    return const <String>[];
  }
  if (v is! List) throw DtoFormatException(key);
  return <String>[for (final Object? item in v) item is String ? item : (throw DtoFormatException(key))];
}

/// `Money` (`{amount, currency}`) → тыйыны; нет — `null`; неверный формат суммы — ошибка формата.
Money? jMoney(JsonMap json, String key) {
  final JsonMap? v = jObject(json, key);
  if (v == null) return null;
  final String? amount = jOpt<String>(v, 'amount');
  if (amount == null) throw DtoFormatException('$key.amount');
  return _parse(() => Money.fromString(amount), '$key.amount');
}

/// Обязательные деньги.
Money jReqMoney(JsonMap json, String key) => jMoney(json, key) ?? (throw DtoFormatException(key));

/// Строка `MoneyAmount` (`"0.00"`, `"-1.50"`) → тыйыны.
Money? jMoneyAmount(JsonMap json, String key) {
  final String? v = jOpt<String>(json, key);
  return v == null ? null : _parse(() => Money.fromString(v), key);
}

/// Деньги в тело запроса (`Money`).
JsonMap moneyJson(Money money) => <String, dynamic>{'amount': money.toApiString(), 'currency': MoneyDto.currencyKgs};

/// `Percent` (`"5.00"`) → сотые доли.
Percent? jPercent(JsonMap json, String key) {
  final String? v = jOpt<String>(json, key);
  return v == null ? null : _parse(() => Percent.fromString(v), key);
}

/// `QuantityValue` (`"124.000"`) → milli-units.
Qty? jQty(JsonMap json, String key) {
  final String? v = jOpt<String>(json, key);
  return v == null ? null : _parse(() => Qty.fromString(v), key);
}

/// Количество со знаком (`CartItem.available` — `^-?\d{1,11}(\.\d{1,3})?$`: 1С допускает отрицательный остаток,
/// EQ-CAT-12) → milli-units со знаком.
Qty? jSignedQty(JsonMap json, String key) {
  final String? v = jOpt<String>(json, key);
  if (v == null) return null;
  final bool negative = v.startsWith('-');
  final Qty abs = _parse(() => Qty.fromString(negative ? v.substring(1) : v), key);
  return negative ? Qty(-abs.milli) : abs;
}

/// Количество со знаком из поля без шаблона в контракте (`CartConflict.available`, `CartConflict.factor`):
/// неразбираемое значение — `null` (предупреждение о конфликте не должно теряться из-за формата числа).
Qty? jLenientQty(JsonMap json, String key) {
  try {
    return jSignedQty(json, key);
  } on DtoFormatException {
    return null;
  }
}

/// Значение перечисления по строке контракта; неизвестное — `null` (совместимость вперёд).
E? jEnum<E>(JsonMap json, String key, E? Function(String? value) tryParse) => tryParse(jOpt<String>(json, key));

/// Обязательное значение перечисления: нет поля — ошибка формата; неизвестное значение — тоже (поле
/// управляет логикой клиента, молча подменять его нельзя).
E jReqEnum<E>(JsonMap json, String key, E? Function(String? value) tryParse) =>
    tryParse(jReq<String>(json, key)) ?? (throw DtoFormatException(key));

T _parse<T>(T Function() parse, String field) {
  try {
    return parse();
  } on Object {
    throw DtoFormatException(field);
  }
}
