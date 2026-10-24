// Слот баннера уведомления центра (RM-F-008: `cart_price_changed` / `cart_stock_changed`, 02 SCR-44.3) в зоне C
// SCR-20 / CartPanel. cart ↛ notifications (DAG 06 §6.1): виджет подставляет композиционный корень
// (`app/di/overrides.dart` → `NotificationBannerSlot`); `null` — слота нет.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Строит баннер уведомления для корзины [cartId].
typedef CartNotificationBannerBuilder = Widget Function(BuildContext context, String cartId);

/// Баннер уведомлений корзины; показывается, когда собственного баннера корзины (офлайн, цены, остатки) нет.
final cartNotificationBannerProvider = Provider<CartNotificationBannerBuilder?>((ref) => null);
