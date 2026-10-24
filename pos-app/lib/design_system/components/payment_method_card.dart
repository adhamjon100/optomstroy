import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart' show PaymentMethod;
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/option_tile.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Плитка способа оплаты `PaymentMethodCard` (03 §9.34; 02 UI-21-012): плитка выбора с иконкой способа —
/// `payments` (`cash`), `qr_code_2` (`qr_bakai`), `receipt_long` (`credit`). Широкая (≥ [stackBelow]) — `OptionTile.radio`
/// (иконка · текст · радио); узкая (3 плитки в ряд на expanded, макет IMG_7090) — та же плитка с иконкой и радио в
/// верхней строке и текстом под ними. Недоступная плитка (`onTap == null`) показывает причину; `credit` при
/// блокировке — обводка `error`, не выбирается (fail-closed). `loading` — «Проверяем долг…» со спиннером. Набор
/// допустимых способов — от сервера (`CheckoutPreview.permissions.allowedPaymentMethods`); тексты — ARB.
class PaymentMethodCard extends StatelessWidget {
  /// Создаёт плитку.
  const PaymentMethodCard({
    super.key,
    required this.method,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.disabledReason,
    this.blocked = false,
    this.loading = false,
    this.loadingLabel,
  });

  /// Способ.
  final PaymentMethod method;

  /// Заголовок («Наличными в кассу»).
  final String title;

  /// Подпись («Оплата в нашем магазине»).
  final String? subtitle;

  /// Выбрана.
  final bool selected;

  /// Выбор; `null` — недоступна.
  final VoidCallback? onTap;

  /// Причина недоступности (вместо подписи).
  final String? disabledReason;

  /// Блокировка долга: обводка `error` (03 §9.34).
  final bool blocked;

  /// Идёт проверка («Проверяем долг…»).
  final bool loading;

  /// Подпись проверки.
  final String? loadingLabel;

  /// Ширина, ниже которой плитка раскладывается в столбик.
  static const double stackBelow = 260;

  /// Иконка способа (03 §9.34).
  static IconData iconOf(PaymentMethod method) => switch (method) {
    PaymentMethod.cash => Icons.payments_outlined,
    PaymentMethod.qrBakai => Icons.qr_code_2_rounded,
    PaymentMethod.credit => Icons.receipt_long_outlined,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final Widget tile = box.maxWidth < stackBelow ? _stacked(context) : _wide();
      if (!blocked && !loading) return tile;
      return Stack(
        children: <Widget>[
          tile,
          if (blocked)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(context.radii.md),
                    border: Border.all(color: context.colors.error, width: 2),
                  ),
                ),
              ),
            ),
          if (loading) const Positioned(top: 12, right: 40, child: AppProgress.circular(size: 16)),
        ],
      );
    },
  );

  Widget _wide() => OptionTile(
    key: ValueKey<String>('payment-method-${method.value}'),
    title: title,
    subtitle: loading ? loadingLabel : subtitle,
    icon: iconOf(method),
    selected: selected,
    onTap: loading ? null : onTap,
    disabledReason: loading ? loadingLabel : disabledReason,
  );

  Widget _stacked(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onTap != null && !loading;
    final String? caption = loading ? loadingLabel : (enabled ? subtitle : (disabledReason ?? subtitle));
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    return Semantics(
      key: ValueKey<String>('payment-method-${method.value}'),
      inMutuallyExclusiveGroup: true,
      selected: selected,
      checked: selected,
      enabled: enabled,
      button: true,
      label: caption == null ? title : '$title. $caption',
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: enabled ? onTap : null,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = !enabled
              ? c.disabledBg
              : selected
              ? (s.pressed ? c.primaryContainerPressed : c.primaryContainer)
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface));
          final (Color border, double width) = !enabled
              ? (c.border, 1.0)
              : selected
              ? (c.primaryText, 2.0)
              : (s.hovered ? c.borderStrong : c.border, 1.0);
          final Color on = enabled ? c.primaryText : c.disabledText;
          return DsFocusRing(
            visible: s.focused,
            borderRadius: radius,
            child: AnimatedContainer(
              duration: context.motion.of(context.motion.fast),
              constraints: const BoxConstraints(minHeight: 72),
              padding: EdgeInsets.all(14 - (width - 1)),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                border: Border.all(color: border, width: width),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        iconOf(method),
                        size: 24,
                        color: !enabled ? c.disabledText : (selected ? c.primaryText : c.textSecondary),
                      ),
                      const Spacer(),
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c.surface,
                          border: Border.all(
                            color: selected ? on : (enabled ? c.borderStrong : c.disabledText),
                            width: 2,
                          ),
                        ),
                        child: selected
                            ? Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(shape: BoxShape.circle, color: on),
                              )
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: context.text.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled ? c.textPrimary : c.disabledText,
                    ),
                  ),
                  if (caption != null)
                    Text(
                      caption,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.caption.copyWith(color: c.textSecondary),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
