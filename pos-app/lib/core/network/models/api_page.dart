// DTO `Page<T>` — курсорная пагинация (08 §2.5; OpenAPI components.schemas.Page).
// Имя `ApiPage` — чтобы не конфликтовать с `Page` из flutter/widgets.
import 'package:freezed_annotation/freezed_annotation.dart';

part 'api_page.freezed.dart';
part 'api_page.g.dart';

@Freezed(genericArgumentFactories: true)
abstract class ApiPage<T> with _$ApiPage<T> {
  const factory ApiPage({
    required List<T> items,
    required String? nextCursor,
    required bool hasMore,
    int? totalEstimate,
    bool? isEstimate,
    DateTime? asOf,
  }) = _ApiPage<T>;

  factory ApiPage.fromJson(Map<String, dynamic> json, T Function(Object? json) fromJsonT) =>
      _$ApiPageFromJson(json, fromJsonT);

  /// Максимум страницы для всех списочных операций (08 §2.5, ядро §19.2).
  static const int maxLimit = 200;
}
