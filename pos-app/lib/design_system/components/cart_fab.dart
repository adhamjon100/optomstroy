import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Плавающая панель-итог корзины `CartFab` (03 §9.30; ядро §17.5; 02 UI-20-019 / UI-10-040): 56 lp на всю ширину
/// минус поля 16, радиус `md`, фон `primary`, `elevation.2` → иконка `shopping_cart` 24 `onPrimary` + бейдж
/// (`AppBadge.onPrimary`) → «Корзина» `body 600 onPrimary` и под ней [caption] «5 поз. · 6 шт»
/// (`cart_counter_units`, SRC-C-061) → [warning] — иконка `warning` при изменениях цен/остатков → итог
/// `bodyLg 700 onPrimary tnum` → шеврон `expand_less`. Текст и иконки на `primary` — только `onPrimary`
/// (белый, 4.64:1 — ADR-111, 03 §5.4). Скрывается вызывающим при пустой корзине и на SCR-20/21.
class CartFab extends StatelessWidget {
  /// Создаёт панель-итог.
  const CartFab({
    super.key,
    required this.label,
    required this.count,
    required this.semanticLabel,
    required this.onTap,
    this.caption,
    this.total,
    this.warning = false,
  });

  /// «Корзина».
  final String label;

  /// Число позиций (строк).
  final int count;

  /// «5 поз. · 6 шт».
  final String? caption;

  /// Итог сервера; `null` — не показывается.
  final Money? total;

  /// Есть изменения цен/остатков.
  final bool warning;

  /// «Открыть корзину, 5 позиций, 16 007 сом 50 тыйын» (`cart_fab_a11y`).
  final String semanticLabel;

  /// Открыть корзину.
  final VoidCallback onTap;

  /// Ключ панели (тесты).
  static const Key fabKey = ValueKey<String>('cart-fab');

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        key: fabKey,
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState st) => DsFocusRing(
          visible: st.focused,
          borderRadius: BorderRadius.all(context.radii.md),
          child: Container(
            height: 56,
            padding: EdgeInsets.symmetric(horizontal: context.space.s4),
            decoration: BoxDecoration(
              color: st.pressed ? c.primaryPressed : c.primary,
              borderRadius: BorderRadius.all(context.radii.md),
              boxShadow: context.elevation.e2,
            ),
            child: Row(
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Icon(Icons.shopping_cart_outlined, size: 24, color: c.onPrimary),
                    PositionedDirectional(
                      top: -8,
                      end: -12,
                      child: AppBadge(count: count, tone: AppBadgeTone.onPrimary),
                    ),
                  ],
                ),
                SizedBox(width: context.space.s5),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        maxLines: 1,
                        style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: c.onPrimary),
                      ),
                      if (caption != null)
                        Text(
                          caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.caption.copyWith(color: c.onPrimary),
                        ),
                    ],
                  ),
                ),
                if (warning) ...<Widget>[
                  Icon(Icons.warning_amber_rounded, size: 20, color: c.onPrimary),
                  SizedBox(width: context.space.s2),
                ],
                if (total != null)
                  Text(
                    PriceText.format(total!, fixed2: true),
                    maxLines: 1,
                    style: context.text.priceOf(context.text.bodyLg).copyWith(color: c.onPrimary),
                  ),
                SizedBox(width: context.space.s1),
                Icon(Icons.expand_less_rounded, size: 24, color: c.onPrimary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
