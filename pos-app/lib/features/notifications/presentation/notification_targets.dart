// Цель перехода по уведомлению (02 SCR-44.3 «Сопоставление видов», SCR-44.6; 02 §8 переходы 18, 26–29;
// visual/navigation.md §2.2 «Правило веток», §5.1). Фича не импортирует `app/router` (AP-01) и строит location сама —
// тем же форматом, что маршруты routes.dart. В query не попадают ПДн (N-3): только идентификаторы.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';

/// Способ перехода: `go` с переключением ветки (цель в другой ветке оболочки) или `push` (root-маршрут /
/// та же ветка `profile`, «Назад» → SCR-44).
enum NotificationNavigation { go, push }

/// Цель уведомления.
final class NotificationLink {
  const NotificationLink(this.location, this.navigation);

  final String location;
  final NotificationNavigation navigation;

  @override
  bool operator ==(Object other) =>
      other is NotificationLink && other.location == location && other.navigation == navigation;

  @override
  int get hashCode => Object.hash(location, navigation);

  @override
  String toString() => 'NotificationLink(${navigation.name} $location)';
}

/// Режим клиента-покупателя (RM-G-014): цели уведомлений — только разделы клиента. По умолчанию `false`; корень
/// (`app/router/shells/customer_mode_bindings.dart`) подставляет вид пользователя сессии, в тестах — `overrideWithValue`.
final notificationsCustomerModeProvider = Provider<bool>((ref) => false);

/// Сопоставление уведомления с целью; `null` — без перехода (только отметка и раскрытие текста).
abstract final class NotificationTargets {
  /// Цель [n]; [customer] — режим клиента (10 CUST-021, CUST-023): `order_status`/`payment_status` → свой заказ
  /// SCR-24, корзина, профиль, сеансы, «О приложении», товар; привязка к карточке 1С → своя карточка SCR-32 или
  /// профиль SCR-41 (статус привязки, переход на SCR-06); служебные цели (синхронизация, долг, возвраты, отложенные
  /// корзины, администрирование) клиенту не открываются.
  static NotificationLink? of(AppNotification n, {bool customer = false}) {
    if (customer) return _forCustomer(n);
    final Map<String, Object?> p = n.payload;
    final String? orderId = n.orderId ?? _id(p['orderId']);
    final String? productId = _id(p['productId']);
    switch (n.kind) {
      case NotificationKind.syncError:
        // SCR-43 — в ветке `profile`, как и SCR-44: `push`, «Назад» → SCR-44 (navigation §5.1).
        return NotificationLink(
          _with('/sync', <String, String?>{'entity': _id(p['entity']), 'runId': _id(p['runId'])}),
          NotificationNavigation.push,
        );
      case NotificationKind.orderStatus:
      case NotificationKind.paymentStatus:
        return orderId == null ? null : NotificationLink(_order(orderId), NotificationNavigation.go);
      case NotificationKind.cartPriceChanged:
      case NotificationKind.cartStockChanged:
        return NotificationLink(
          _with('/cart', <String, String?>{'cartId': _id(p['cartId'])}),
          NotificationNavigation.go,
        );
      case NotificationKind.creditBlocked:
        if (orderId != null) return NotificationLink(_order(orderId), NotificationNavigation.go);
        final String? customerId = _id(p['customerId']);
        return customerId == null
            ? null
            : NotificationLink('/customers/${Uri.encodeComponent(customerId)}', NotificationNavigation.go);
      case NotificationKind.returnStatus:
        final String? returnId = _id(p['returnId']);
        return returnId == null
            ? null
            : NotificationLink('/returns/${Uri.encodeComponent(returnId)}', NotificationNavigation.push);
      case NotificationKind.system:
        // Истечение отложенной корзины: `kind=system`, `payload.target = cart_parked` (OpenAPI 1.2.0, 08 §3.13;
        // FQ-NOTIF-07) → SCR-23 (02 §8 п. 27). Значения нет в `NotificationTarget` домена — читается из payload.
        if (p['target'] == cartParkedTarget) return const NotificationLink('/cart/parked', NotificationNavigation.go);
        return switch (n.target) {
          NotificationTarget.sessions => const NotificationLink(
            '/settings?section=sessions',
            NotificationNavigation.push,
          ),
          NotificationTarget.profile => const NotificationLink('/profile', NotificationNavigation.go),
          NotificationTarget.customerLink => _customerLink(p),
          NotificationTarget.update => const NotificationLink('/settings?section=about', NotificationNavigation.push),
          null => null,
        };
      case null:
        // Неизвестный вид (совместимость вперёд): переход к товару, если он указан (02 §8 п. 18).
        break;
    }
    if (productId != null) {
      return NotificationLink(
        _with('/catalog/p/${Uri.encodeComponent(productId)}', <String, String?>{'variantId': _id(p['variantId'])}),
        NotificationNavigation.go,
      );
    }
    return null;
  }

  static NotificationLink? _forCustomer(AppNotification n) {
    switch (n.kind) {
      case NotificationKind.orderStatus:
      case NotificationKind.paymentStatus:
      case NotificationKind.cartPriceChanged:
      case NotificationKind.cartStockChanged:
        return of(n);
      case NotificationKind.system:
        if (n.payload['target'] == cartParkedTarget) return null;
        if (n.target == NotificationTarget.customerLink) {
          final String? customerId = _id(n.payload['customerId']);
          return customerId == null
              ? const NotificationLink('/profile', NotificationNavigation.go)
              : NotificationLink('/customers/${Uri.encodeComponent(customerId)}', NotificationNavigation.go);
        }
        return of(n);
      case NotificationKind.syncError:
      case NotificationKind.creditBlocked:
      case NotificationKind.returnStatus:
        return null;
      case null:
        return of(n);
    }
  }

  /// `payload.target` истечения отложенной корзины (08 §3.13).
  static const String cartParkedTarget = 'cart_parked';

  /// «Это не я» (`system`, вход с нового устройства) → SCR-42 «Сеансы».
  static const NotificationLink sessions = NotificationLink('/settings?section=sessions', NotificationNavigation.push);

  static NotificationLink _customerLink(Map<String, Object?> p) {
    final String? customerId = _id(p['customerId']);
    return customerId == null
        ? const NotificationLink('/admin/users', NotificationNavigation.go)
        : NotificationLink('/customers/${Uri.encodeComponent(customerId)}', NotificationNavigation.go);
  }

  static String _order(String orderId) => '/orders/${Uri.encodeComponent(orderId)}';

  static String? _id(Object? v) => v is String && v.isNotEmpty ? v : null;

  static String _with(String path, Map<String, String?> query) {
    final Map<String, String> q = <String, String>{
      for (final MapEntry<String, String?> e in query.entries)
        if (e.value != null) e.key: e.value!,
    };
    return q.isEmpty ? path : Uri(path: path, queryParameters: q).toString();
  }
}
