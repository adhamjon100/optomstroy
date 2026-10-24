// Переходы из сканера (02 SCR-17.6, п. 2.2.11). Фичи не импортируют app/ (AP-01), поэтому
// пути строятся строкой по маршрутам `app/router/routes.dart` (ProductRoute, CatalogSearchRoute).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';

/// Пути экранов, куда ведёт скан.
abstract final class ScanLocations {
  /// SCR-14 `/catalog/p/:productId?variantId=&qty=`.
  static String product(ScanLookupResult r) {
    final qty = r.packagingId != null ? r.suggestedQuantity?.toApiString() : null;
    return Uri(
      path: '/catalog/p/${Uri.encodeComponent(r.productId)}',
      queryParameters: <String, String>{'variantId': r.variantId, 'qty': ?qty},
    ).toString();
  }

  /// SCR-11 `/catalog/search?q=`.
  static String search([String? q]) => Uri(
    path: '/catalog/search',
    queryParameters: q == null || q.isEmpty ? null : <String, String>{'q': q},
  ).toString();

  /// SCR-17 `/scan?mode=`.
  static String scan(ScanMode mode) =>
      Uri(path: '/scan', queryParameters: <String, String>{'mode': mode.value}).toString();
}

/// Закрыть сканер с результатом [result] (`pop(result)`), затем, если задан [then], открыть путь
/// из экрана-источника (02 SCR-17.6: «pop(result) → push»).
void closeScanner(BuildContext context, {Object? result, String? then, bool replaceWithGo = false}) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    unawaited(Navigator.of(context).maybePop(result));
    return;
  }
  if (router.canPop()) router.pop(result);
  if (then == null) return;
  if (replaceWithGo) {
    router.go(then);
  } else {
    // Результат push в источнике не нужен.
    unawaited(router.push<void>(then));
  }
}
