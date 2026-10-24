// Режим клиента-покупателя в экранах каталога (RM-E-017; ядро v1.9 §24.2; 02 SCR-50, ч. B — вариант
// `customer`; 10 CUST-021, CUST-022). Точки подключения без межфичевого импорта (06 §6.1, FL-03):
// значения по умолчанию безопасны (остатки — `status`, без чисел; режим клиента включён; сводка
// «Мой кабинет» не загружается), реальные источники подставляет композиционный корень
// (`app/router/shells/customer_mode_bindings.dart` → `appOverrides`), в тестах — `overrideWithValue`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';

/// `app_settings.customer_stock_display` из `GET /settings/public` (08 §4.23.1): `status` — только
/// «в наличии / мало / нет» без количества; `quantity` — плюс доступное количество (без «остатка» и
/// «резерва»). Количества клиенту исключает и сервер (08 API-180) — клиент их не вычисляет.
final catalogCustomerStockDisplayProvider = Provider<CustomerStockDisplay>((ref) => CustomerStockDisplay.status);

/// `features.customerSelfService` (`GET /settings/public`; ядро §19.2 — флаг только env). `false` —
/// SCR-50 показывает состояние UI-50-015 «Сервис для покупателей временно недоступен».
final catalogCustomerSelfServiceProvider = Provider<bool>((ref) => true);

/// Сводка «Мой кабинет» SCR-50 (UI-50-003…006, UI-50-014): привязка к карточке 1С, заказы в работе,
/// свой долг. Финансы не кэшируются на устройстве (ядро §18.2 п. 1).
final class CustomerHomeSummary {
  const CustomerHomeSummary({
    this.linkStatus,
    this.linkName,
    this.customerId,
    this.activeOrders,
    this.hasActiveOrders = false,
    this.debt,
    this.debtAsOf,
  });

  /// Статус привязки (`Me.customerLink.status`); `null` — привязки нет (`none`).
  final CustomerLinkStatus? linkStatus;

  /// Маскированное название организации для баннера `proposed` (`displayNameMasked`).
  final String? linkName;

  /// Карточка клиента 1С (`Me.customerLink.customerId`, только `confirmed`) — переход на SCR-34.
  final String? customerId;

  /// Заказы «в работе» (`totalEstimate` ответа `GET /orders`); `null` — число неизвестно.
  final int? activeOrders;

  /// Заказы в работе есть, но `totalEstimate` не пришёл — «Есть заказы в работе» без числа.
  final bool hasActiveOrders;

  /// Свой долг (`GET /customers/{id}/receivables`, только `confirmed`); `null` — «Нет данных из 1С».
  final Money? debt;

  /// Время снимка долга (метка «данные от HH:MM»).
  final DateTime? debtAsOf;

  /// Привязка подтверждена — доступны долг и скидка карточки 1С (ядро §22.12).
  bool get linked => linkStatus == CustomerLinkStatus.confirmed;
}

/// Источник сводки «Мой кабинет» (адаптер `GET /me` + `GET /orders` + receivables — в корне).
abstract interface class CustomerHomePort {
  /// Сводка для SCR-50; ошибка — карточки показывают значения по умолчанию, экран работает.
  Future<Result<CustomerHomeSummary>> summary();
}

/// Порт сводки; `null` — карточки «Мой кабинет» без чисел, баннер привязки скрыт.
final customerHomePortProvider = Provider<CustomerHomePort?>((ref) => null);

/// Сводка «Мой кабинет» (pull-to-refresh — `ref.invalidate`).
final customerHomeSummaryProvider = FutureProvider.autoDispose<CustomerHomeSummary?>((ref) async {
  final CustomerHomePort? port = ref.watch(customerHomePortProvider);
  if (port == null) {
    return null;
  }
  try {
    return (await port.summary()).valueOrNull;
  } on Object {
    return null;
  }
});

/// Число строк локальной корзины-черновика (`CartFab` / кнопка корзины в шапке E, UI-50-011).
/// Без привязки корзины (`cartDraftRepositoryProvider`) — 0: кнопка скрыта.
final catalogCartDraftCountProvider = StreamProvider.autoDispose<int>((ref) {
  try {
    final CartDraftRepository repo = ref.watch(cartDraftRepositoryProvider);
    return repo.watchLines().map((List<CartDraftLine> lines) => lines.length);
  } on Object {
    return Stream<int>.value(0);
  }
});
