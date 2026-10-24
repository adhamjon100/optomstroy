// Справочники каталога (08 §3.6; OpenAPI `Unit`, `CatalogWarehouse`, `CatalogPriceList`,
// `Packaging`, `CatalogSyncBarcode`, `Image`). Реплика 1С, только чтение (D-28). Чистый Dart (FL-01).
// Количества — `Qty` (milli-units), деньги — `Money` (тыйыны); `double` не используется (D-19).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Единица измерения (`Unit`).
final class Unit {
  const Unit({required this.id, required this.name, required this.qtyPrecision, this.code, this.shortName});

  /// Серверный UUID (на него ссылаются `unitId` варианта, упаковки и остатка).
  final String id;
  final String? code;
  final String name;

  /// Краткое имя («шт», «м²»).
  final String? shortName;

  /// Число знаков после запятой в количестве (0…3, `qty_precision`).
  final int qtyPrecision;

  /// Подпись для UI: краткое имя, иначе полное.
  String get label => shortName ?? name;
}

/// Склад (`CatalogWarehouse`, `CatalogSyncWarehouse`).
final class Warehouse {
  const Warehouse({
    required this.id,
    required this.name,
    this.code,
    this.isActive = true,
    this.isDefaultForPos = false,
    this.shortName,
  });

  final String id;
  final String name;
  final String? code;
  final String? shortName;
  final bool isActive;

  /// Склад по умолчанию для POS (`isDefaultForPos`).
  final bool isDefaultForPos;
}

/// Вид цены (`CatalogPriceList`). Клиенту приходят только виды цен, разрешённые его роли (DATA-262).
final class PriceList {
  const PriceList({
    required this.id,
    required this.name,
    this.code,
    this.currency = 'KGS',
    this.isDefault = false,
    this.visibleToRoles = const <RoleCode>[],
  });

  final String id;
  final String name;
  final String? code;
  final String currency;
  final bool isDefault;
  final List<RoleCode> visibleToRoles;
}

/// Упаковка (`Packaging`): коэффициент к базовой единице [factor] — целое число milli-units > 0.
final class Packaging {
  const Packaging({
    required this.id,
    required this.unitId,
    required this.factor,
    this.name,
    this.isDefault = false,
    this.allowFraction = false,
    this.barcode,
    this.variantId,
  });

  final String id;
  final String unitId;
  final String? name;
  final Qty factor;
  final bool isDefault;

  /// Разрешено дробное количество упаковок (обычно — нет, INV-006).
  final bool allowFraction;
  final String? barcode;

  /// Вариант, к которому относится упаковка (`CatalogSyncPackaging.variantId`).
  final String? variantId;
}

/// Штрихкод (`CatalogSyncBarcode`; офлайн-сканер — DATA-259). Тип — `BarcodeType` из core/enums.
final class Barcode {
  const Barcode({required this.value, required this.variantId, required this.type, this.packagingId, this.productId});

  final String value;
  final String variantId;
  final String? packagingId;
  final BarcodeType type;
  final String? productId;
}

/// Фото товара (`Image`): файл неизменяем, адресуется `sha256` (D-30). Размеры: `thumb` 160,
/// `card` 400, `full` 1200 (RM-E-003); URL относительные (`/api/v1/images/{sha}/{size}`).
final class ProductImageRef {
  const ProductImageRef({
    required this.sha256,
    this.thumbUrl,
    this.cardUrl,
    this.fullUrl,
    this.isPrimary = false,
    this.width,
    this.height,
    this.productId,
    this.variantId,
    this.sortOrder = 0,
  });

  final String sha256;
  final String? thumbUrl;
  final String? cardUrl;
  final String? fullUrl;
  final bool isPrimary;

  /// Размеры оригинала в пикселях (если сервер их прислал).
  final int? width;
  final int? height;
  final String? productId;
  final String? variantId;
  final int sortOrder;
}
