// Точки подключения экранов заказов SCR-24/SCR-25 к сессии, сети, печати и корзине без межфичевого импорта
// (06 §6.1: orders зависит только от customers; app/ — композиционный корень). Значения по умолчанию безопасны:
// роль неизвестна — служебные действия скрыты; печать — пакет `printing`; «Скачать PDF» и «Повторить заказ»
// скрыты, пока корень не подставит реализацию; печать — `PrintingOrderDocumentPrinter` (подключает корень). Подключение — `app/di/overrides.dart` (интегратор), в тестах —
// `overrideWithValue(...)`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' show StepUpChallenge, StepUpCoordinator;
import 'package:optomstroy/features/orders/domain/entities/order.dart';

/// Кто смотрит заказы: роль и пользователь сессии + настройки, влияющие на действия SCR-24/25.
///
/// Права выводятся из роли по матрице `contracts/rbac/permissions.yaml` (11 §4.3–§4.4); сервер проверяет их
/// независимо (кнопки — подсказка, не защита).
@immutable
final class OrdersViewer {
  /// Создаёт описание зрителя.
  const OrdersViewer({this.role, this.userId, this.qrShowEnabled = true});

  /// Роль сессии; `null` — неизвестна (до входа) — служебные действия скрыты.
  final RoleCode? role;

  /// `sub` пользователя («Мои» = `createdBy`).
  final String? userId;

  /// Показ QR доступен (`QR_PROVIDER≠none`; для `customer` — `QR_PROVIDER=onec`, ядро v1.9 §24.4).
  final bool qrShowEnabled;

  /// Режим клиента (ядро §24.2).
  bool get isCustomer => role == RoleCode.customer;

  /// Сотрудник магазина.
  bool get isStaff => role != null && role != RoleCode.customer && role != RoleCode.integration;

  /// `order.read.all` — список всех и переключатель «Мои / Все».
  bool get canReadAll => switch (role) {
    RoleCode.cashier || RoleCode.seniorSeller || RoleCode.admin || RoleCode.owner => true,
    _ => false,
  };

  /// `order.documents.print` (у `customer` — только счёт, 02 SCR-24.10).
  bool get canPrint => role != null && role != RoleCode.integration;

  /// `payment.cash.receive` — «Принять оплату» (02 AC-UI-24-007: не у `seller`, `admin`, `owner`).
  bool get canAcceptPayment => role == RoleCode.cashier || role == RoleCode.seniorSeller;

  /// `payment.qr.show` — «Показать QR».
  bool get canShowQr => switch (role) {
    RoleCode.seller || RoleCode.cashier || RoleCode.seniorSeller || RoleCode.customer => qrShowEnabled,
    _ => false,
  };

  /// `order.onec_link` — «Привязать к документу 1С» (02 AC-UI-24-015).
  bool get canOnecLink => role == RoleCode.seniorSeller || role == RoleCode.admin || role == RoleCode.owner;

  /// `cart.manage.own` — «Повторить заказ» (не у `owner`).
  bool get canRepeat => switch (role) {
    RoleCode.seller || RoleCode.cashier || RoleCode.seniorSeller || RoleCode.admin || RoleCode.customer => true,
    _ => false,
  };

  /// `order.create` — «Создать заказ» в `EmptyState.orders`.
  bool get canCreateOrder => canRepeat;

  /// Карточка клиента SCR-32 и долг — только сотрудникам.
  bool get canOpenCustomerCard => isStaff;

  @override
  bool operator ==(Object other) =>
      other is OrdersViewer && other.role == role && other.userId == userId && other.qrShowEnabled == qrShowEnabled;

  @override
  int get hashCode => Object.hash(role, userId, qrShowEnabled);
}

/// Зритель заказов; корень подставляет роль и пользователя сессии и режим `QR_PROVIDER`.
final ordersViewerProvider = Provider<OrdersViewer>((ref) => const OrdersViewer());

/// Доступность сети: `offline`/`serverDown` — `OfflineBanner`, действия disabled (D-32). По умолчанию `unknown`;
/// корень подставляет `onlineStatusProvider` (core/di).
final ordersOnlineStatusProvider = Provider<OnlineStatus>((ref) => OnlineStatus.unknown);

/// Показ и печать PDF документа заказа (02 раздел 3.9: только память/временный каталог, без «Поделиться», Q-264).
abstract interface class OrderDocumentPrinter {
  /// Просмотр (`DocumentPreview`).
  Future<void> preview(BuildContext context, OrderDocumentFile file);

  /// Системный диалог печати; `true` — отправлено на печать.
  Future<bool> print(OrderDocumentFile file);
}

/// Печать/просмотр документов заказа; `null` — кнопки «Просмотр»/«Печать» скрыты. Реализация на пакете `printing` —
/// [PrintingOrderDocumentPrinter] (`printing_document_printer.dart`), подключает корень: файл вынесен, чтобы экраны и их
/// тесты не компилировали `printing` (FQ-FEORD-09: `image` 4.11.0 несовместим с `archive` 4.0.9 в pubspec.lock).
final orderDocumentPrinterProvider = Provider<OrderDocumentPrinter?>((ref) => null);

/// «Скачать PDF» — только системный диалог «Сохранить как…» после предупреждения о ПДн (02 SCR-24.4, AC-UI-24-017).
abstract interface class OrderDocumentSaver {
  /// Сохранить [file] через системный диалог; `false` — пользователь отменил.
  Future<bool> saveAs(OrderDocumentFile file);
}

/// Сохранение PDF; `null` — кнопка «Скачать PDF» скрыта (нужен системный диалог сохранения — `file_selector`/SAF,
/// зависимость запрошена отдельно).
final orderDocumentSaverProvider = Provider<OrderDocumentSaver?>((ref) => null);

/// «Повторить заказ» (02 UI-24-011, UI-24-020): строки добавляются в активную корзину по текущим ценам
/// (`PUT /cart/items/{variantId}` `mode=increment`). Реализацию над `CartRepository` подставляет корень
/// (orders ↛ cart, 06 §6.1).
abstract interface class OrderRepeatPort {
  /// Число позиций активной корзины (непустая — диалог UI-24-020).
  Future<Result<int>> activeCartItemsCount();

  /// Отложить текущую корзину (`POST /cart/park`) и начать новую.
  Future<Result<void>> parkActiveCart({required String idempotencyKey});

  /// Добавить строку заказа; `Success(false)` — вариант снят с продажи (строка пропущена).
  Future<Result<bool>> addLine(OrderLine line, {required String idempotencyKey});
}

/// Порт повтора заказа; `null` — кнопка «Повторить заказ» скрыта.
final orderRepeatPortProvider = Provider<OrderRepeatPort?>((ref) => null);

/// «Открыть восстановленную корзину» (02 UI-24-015, SCR-24.6; 10 ORD-027): путь корзины, в которую сервер восстановил
/// состав заказа `submit_failed`, — SCR-20 (`/cart`, восстановленная стала активной) или SCR-23 (`/cart/parked`).
/// orders ↛ cart (06 §6.1): реализацию подставляет корень; `null` — кнопки нет (роль без корзины).
typedef OrderRestoredCartLocator = Future<String> Function(String orderId);

/// Поиск восстановленной корзины для SCR-24.
final orderRestoredCartLocatorProvider = Provider<OrderRestoredCartLocator?>((ref) => null);

/// Итог step-up до запроса: [cancelled] — пользователь закрыл `StepUpDialog` (запрос не отправляется);
/// [token] `null` без отмены — диалог не смонтирован, step-up выполнит AuthInterceptor по `403 STEP_UP_REQUIRED`.
typedef OrdersStepUpResult = ({bool cancelled, String? token});

/// Step-up до запроса для операций, где он обязателен (`order.onec_link`, 02 SCR-24.4 п. «Привязать»).
typedef OrdersStepUp = Future<OrdersStepUpResult> Function(String operation);

/// По умолчанию — `StepUpCoordinator` core/session (StepUpDialog, кэш токена области 15 мин).
final ordersStepUpProvider = Provider<OrdersStepUp>((ref) {
  return (String operation) async {
    final StepUpCoordinator coordinator = ref.read(stepUpCoordinatorProvider);
    if (!coordinator.hasPresenter) return (cancelled: false, token: null);
    final String? token = await coordinator.obtain(StepUpChallenge(operation: operation));
    return (cancelled: token == null, token: token);
  };
});

/// Слот баннера уведомления центра на SCR-24 (RM-F-008: `credit_blocked` по заказу; 02 SCR-44.3).
/// orders ↛ notifications (DAG 06 §6.1): виджет подставляет корень; `null` — слота нет.
typedef OrderNotificationBannerBuilder = Widget Function(BuildContext context, String orderId);

/// Баннер уведомлений заказа.
final orderNotificationBannerProvider = Provider<OrderNotificationBannerBuilder?>((ref) => null);
