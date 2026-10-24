// Публичный контракт фичи product_details (06 §6.1 L-3 (2), §6.14; FL-07).
//
// SCR-14 «Карточка товара», SCR-15 «Выбор варианта» (лист), SCR-16 «Ввод количества» (нампад).
// Данные — порты фич catalog (`catalogRepositoryProvider`, роль `catalogViewerRoleProvider`) и cart
// (`cartDraftRepositoryProvider`), DAG 06 §6.1: product_details → catalog, cart.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';

/// Показ остатков клиенту-покупателю (`app_settings.customer_stock_display`, ядро v1.9 §24.2).
///
/// Провайдера `GET /settings/public` в каркасе нет (EQ-FEF-08) — значение по умолчанию `status`
/// (без чисел); после появления провайдера публичных настроек корень `app/di/overrides.dart`
/// подставляет значение сервера. Сервер в режиме `status` чисел и так не передаёт (02 SCR-14.10).
final customerStockDisplayProvider = Provider<CustomerStockDisplay>((ref) => CustomerStockDisplay.status);

/// Базовый адрес API для фото товара (`/images/{sha256}/{size}.webp`, RM-E-003): относительные
/// URL `Image.*Url` разрешаются от него.
final productImageBaseUriProvider = Provider<Uri>((ref) => ref.watch(appConfigProvider).apiBaseUrl);

/// Порог «данные устарели» для метки «обновлено HH:MM» (INV-027: 30 мин).
final productStockStaleAfterProvider = Provider<Duration>((ref) => const Duration(minutes: 30));

/// Избранное для звезды SCR-14 (A3, `FavoriteToggle`, FAV-002). Ребра `product_details → favorites` в DAG нет
/// (06 §6.1, EQ-PD-03): SCR-14 объявляет порт, адаптер к фиче favorites и outbox подключает композиционный корень
/// (`app/router/shells/customer_mode_bindings.dart`, тот же адаптер, что у `CatalogShelfPort`).
abstract interface class ProductFavoritePort {
  /// Избранное (id товаров) — локальный кэш с неподтверждёнными действиями.
  Stream<Set<String>> watchFavoriteIds();

  /// Добавить/убрать (optimistic + outbox `favorite.add|remove` — у реализации).
  Future<Result<void>> setFavorite(String productId, {required bool favorite});
}

/// Порт избранного SCR-14; `null` — звезда не показывается.
final productFavoritePortProvider = Provider<ProductFavoritePort?>((ref) => null);
