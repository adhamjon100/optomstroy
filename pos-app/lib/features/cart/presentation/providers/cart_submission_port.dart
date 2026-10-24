// Блокировка корзины UI-20-020 «Проверяем результат создания заказа…» (02 SCR-20.11, SCR-20.11.1; 10 CART-022 (а)):
// результат `POST /orders` неизвестен — повторы и поиск заказа по ключу ведёт фича checkout. cart ↛ checkout (DAG
// 06 §6.1): состояние и оверлей подставляет композиционный корень (`app/di/overrides.dart`).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Корзина заблокирована: изменения, «Отложить» и «Создать заказ» недоступны.
final cartSubmissionLockedProvider = Provider<bool>((ref) => false);

/// Строит оверлей блокировки поверх зон D–G `CartPanel`.
typedef CartSubmissionOverlayBuilder = Widget Function(BuildContext context);

/// Оверлей блокировки (`null` — простой индикатор ожидания).
final cartSubmissionOverlayProvider = Provider<CartSubmissionOverlayBuilder?>((ref) => null);
