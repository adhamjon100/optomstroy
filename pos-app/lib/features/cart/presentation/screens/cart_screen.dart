// SCR-20 «Корзина» (`/cart?cartId=`; 02 ч. C SCR-20; роли seller, cashier, senior_seller, admin, customer).
// Владелец реализации — агент F-fe-cart (RM-F-005, RM-F-013, RM-F-015). На medium и шире корзина сотрудника —
// drawer 420 (`CartDrawer`, ADR-112, D5) по кнопке-итогу шапки и `F4`; этот маршрут — экран compact (вкладка
// «Корзина», `CartFab`) и прямой переход на широком окне (deep link, уведомления, восстановление; панель по центру, 640).
//
// `cartId` маршрута: корзина всегда активная корзина пользователя (`GET /cart`); иной `cartId` (отложенная) открывается
// через SCR-23 «Продолжить» (08 §4.7.6) — параметр сохраняется ради ссылок из уведомлений (FQ-CART-04).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';

/// SCR-20.
class CartScreen extends ConsumerWidget {
  /// Экран SCR-20.
  const CartScreen({this.cartId, super.key});

  /// Корзина (по умолчанию — активная).
  final String? cartId;

  /// Ключ экрана (тесты маршрутов): `stub-SCR-20`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-20');

  /// Ширина корзины на широком окне при прямом переходе на `/cart`.
  static const double wideMaxWidth = 640; // money-double: allow — геометрия UI (lp)

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final WindowClass wc = context.windowClass;
    const Widget panel = CartPanelView(variant: CartPanelVariant.screen);
    return Scaffold(
      key: stubKey,
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: wc == WindowClass.compact
            ? panel
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: wideMaxWidth),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.symmetric(vertical: BorderSide(color: context.colors.border)),
                    ),
                    child: panel,
                  ),
                ),
              ),
      ),
    );
  }
}
