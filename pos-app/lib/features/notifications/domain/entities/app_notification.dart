// In-app уведомление (08 §3.13 `Notification`; D-41, RM-F-008). Заголовок и текст сервер формирует без сумм и ПДн
// клиента; для `credit_blocked`, `payment_status`, `return_status` текст на диск не пишется (DATA-258). Чистый Dart.
import 'package:optomstroy/core/enums.dart';

/// Цель перехода для `kind=system` (`payload.target`, ядро §19.2).
enum NotificationTarget {
  sessions('sessions'),
  profile('profile'),
  customerLink('customer_link'),
  update('update');

  const NotificationTarget(this.value);

  final String value;

  static NotificationTarget? tryParse(Object? value) {
    for (final NotificationTarget t in values) {
      if (t.value == value) return t;
    }
    return null;
  }
}

/// Уведомление (`Notification`).
final class AppNotification {
  const AppNotification({
    required this.id,
    required this.rawKind,
    required this.title,
    required this.createdAt,
    required this.severity,
    this.body,
    this.orderId,
    this.paymentId,
    this.target,
    this.rawTarget,
    this.status,
    this.cartId,
    this.entity,
    this.runId,
    this.task,
    this.outboxId,
    this.payload = const <String, Object?>{},
    this.readAt,
  });

  /// `payload.target = cart_parked` (OpenAPI 1.2.0, 08 §3.13): истечение отложенной корзины, переход SCR-44 → SCR-23
  /// по [cartId]. В [NotificationTarget] значение не добавлено, чтобы не ломать исчерпывающие `switch` экрана до его
  /// правки: экран сравнивает [rawTarget] с этой константой.
  static const String targetCartParked = 'cart_parked';

  /// `payload.task = refund_or_advance` — «деньги: возврат / аванс» (10 ORD-035; 08 §3.13). Набор расширяемый.
  static const String taskRefundOrAdvance = 'refund_or_advance';

  final String id;

  /// Вид как пришёл (неизвестный сохраняется — совместимость вперёд).
  final String rawKind;
  final String title;
  final String? body;

  /// `payload.orderId` — переход на SCR-24.
  final String? orderId;

  /// `payload.paymentId` (`payment_status`).
  final String? paymentId;

  /// `payload.target` (`system`).
  final NotificationTarget? target;

  /// `payload.target` как пришёл (в т. ч. [targetCartParked] и значения, неизвестные сборке).
  final String? rawTarget;

  /// `payload.status` — статус объекта для StatusChip: `OrderStatus` (order_status), `PaymentStatus`
  /// (payment_status), статус прогона (синхронизация). Строка: набор зависит от вида (08 §3.13, OpenAPI 1.2.0).
  final String? status;

  /// `payload.cartId` — уведомления корзины, в т. ч. [targetCartParked].
  final String? cartId;

  /// `payload.entity` — сущность синхронизации (`SyncEntity`); неизвестное значение — `null`.
  final SyncEntity? entity;

  /// `payload.runId` — прогон синхронизации.
  final String? runId;

  /// `payload.task` (например, [taskRefundOrAdvance]); неизвестное значение клиент игнорирует (08 §2.11).
  final String? task;

  /// `payload.outboxId` — элемент outbox 1С.
  final String? outboxId;

  /// Прочие поля `payload` (`additionalProperties: true`).
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final DateTime? readAt;
  final NotificationSeverity severity;

  NotificationKind? get kind => NotificationKind.tryParse(rawKind);
  bool get isRead => readAt != null;
}

/// Страница `GET /notifications` + `unreadCount` (бейдж `NotificationBell`).
final class NotificationsPage {
  const NotificationsPage({required this.items, required this.unreadCount, this.nextCursor, this.hasMore = false});

  final List<AppNotification> items;
  final int unreadCount;
  final String? nextCursor;
  final bool hasMore;
}

/// Параметры `GET /notifications`.
final class NotificationsQuery {
  const NotificationsQuery({
    this.unreadOnly = false,
    this.kinds = const <NotificationKind>{},
    this.since,
    this.limit = 50,
    this.cursor,
  });

  /// SCR-44 `/notifications?unread=1`.
  final bool unreadOnly;
  final Set<NotificationKind> kinds;

  /// Инкрементальный опрос (каждые 60 с, при старте и возврате в foreground).
  final DateTime? since;

  /// 1…100.
  final int limit;
  final String? cursor;
}
