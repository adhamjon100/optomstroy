// Порт разбора JSON каталога для фич-потребителей (favorites): DTO `ProductSummary` и
// `CatalogRecentProduct` разбирает только catalog/data (ADR-085), а `features/<f>/data/**`
// чужой фичи не импортируется (FL-06, L-3). Реализация — catalog/data, провайдер —
// `catalogJsonDecoderProvider` (catalog_providers.dart). Чистый Dart (FL-01).
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

abstract interface class CatalogJsonDecoder {
  /// `ProductSummary` из тела ответа; неверная форма → исключение формата (ловит `ErrorMapper.guard`).
  ProductSummary productSummary(Object? json);

  /// `CatalogRecentProduct` (`ProductSummary` + `viewedAt`).
  RecentProduct recentProduct(Object? json);
}
