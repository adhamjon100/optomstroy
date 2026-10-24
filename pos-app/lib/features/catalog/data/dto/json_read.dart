// Чтение JSON для ручных DTO каталога (ADR-085): обязательные поля — исключение формата,
// необязательные — `null` при отсутствии или неверном типе (совместимость вперёд).
import 'package:optomstroy/core/network/models/money_dto.dart';

/// Ответ не соответствует контракту (нет обязательного поля / неверный тип).
final class CatalogDtoException implements Exception {
  const CatalogDtoException(this.field);

  final String field;

  @override
  String toString() => 'CatalogDtoException($field)';
}

typedef Json = Map<String, dynamic>;

/// Тело ответа как объект JSON.
Json asJson(Object? data, [String field = 'body']) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return data.cast<String, dynamic>();
  throw CatalogDtoException(field);
}

T req<T>(Json json, String key) {
  final Object? v = json[key];
  if (v is T) return v;
  throw CatalogDtoException(key);
}

T? opt<T>(Json json, String key) {
  final Object? v = json[key];
  return v is T ? v : null;
}

/// Целое: JSON-числа приходят как `int` (на вебе — `num`).
int? optInt(Json json, String key) {
  final Object? v = json[key];
  if (v is int) return v;
  if (v is num && v == v.roundToDouble()) return v.toInt(); // money-double: allow — JSON-число → int (не деньги)
  return null;
}

int reqInt(Json json, String key) => optInt(json, key) ?? (throw CatalogDtoException(key));

bool? optBool(Json json, String key) => opt<bool>(json, key);

DateTime? optDate(Json json, String key) {
  final String? v = opt<String>(json, key);
  return v == null ? null : DateTime.tryParse(v);
}

DateTime reqDate(Json json, String key) => optDate(json, key) ?? (throw CatalogDtoException(key));

/// Объект JSON по ключу (`null` — нет или не объект).
Json? optObject(Json json, String key) {
  final Object? v = json[key];
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.cast<String, dynamic>();
  return null;
}

Json reqObject(Json json, String key) => optObject(json, key) ?? (throw CatalogDtoException(key));

/// Список объектов; элементы, не являющиеся объектами, — ошибка формата.
List<T> objectList<T>(Json json, String key, T Function(Json item) parse, {bool required = false}) {
  final Object? v = json[key];
  if (v == null) {
    if (required) throw CatalogDtoException(key);
    return <T>[];
  }
  if (v is! List) throw CatalogDtoException(key);
  return [for (final item in v) parse(asJson(item, key))];
}

/// Список строк (`null` → пустой список).
List<String> stringList(Json json, String key, {bool required = false}) {
  final Object? v = json[key];
  if (v == null) {
    if (required) throw CatalogDtoException(key);
    return const <String>[];
  }
  if (v is! List) throw CatalogDtoException(key);
  return [for (final item in v) item is String ? item : (throw CatalogDtoException(key))];
}

/// Словарь «строка → строка» (`attributes`); нестроковые значения приводятся `toString()`.
Map<String, String> stringMap(Json json, String key) {
  final Json? v = optObject(json, key);
  if (v == null) return const <String, String>{};
  return {for (final e in v.entries) e.key: e.value is String ? e.value as String : '${e.value}'};
}

MoneyDto? optMoney(Json json, String key) {
  final Json? v = optObject(json, key);
  return v == null ? null : MoneyDto.fromJson(v);
}

MoneyDto reqMoney(Json json, String key) => optMoney(json, key) ?? (throw CatalogDtoException(key));
