import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Состояние строки `CartLine` (02 UI-20-006, UI-20-011; 03 §9.28).
enum CartLineTone {
  /// Обычная строка.
  normal,

  /// Цена изменилась — фон `warningContainer`.
  warning,

  /// Недостаточный остаток / отказ — полоса слева 3 lp `error`.
  error,

  /// Товар больше не продаётся — приглушена.
  unavailable,
}

/// Строка позиции корзины `CartLine` (03 §9.28): высота 64/72, паддинг 12 → `ProductImage` 48 (thumb) → колонка:
/// название `body 14/500` (2 строки; [dense] — 1), [variantLabel], [subtitle] «Арт. F4252 · 2 350 сом/шт»
/// `caption textSecondary tnum`, [message] (иконка + текст, A11Y-004) и [actions] → [quantity] (степпер
/// вызывающего) → сумма строки `bodyLg 16/700 textPrimary` (ширина ≥ 88; [preliminary] — «≈» `textSecondary`,
/// [pending] — индикатор 16) → `AppIconButton close 20` «Удалить» (цель 44).
///
/// Сумма строки — только ответ сервера (D-23): компонент её не вычисляет.
class CartLine extends StatelessWidget {
  /// Создаёт строку.
  const CartLine({
    super.key,
    required this.title,
    required this.quantity,
    required this.removeLabel,
    this.subtitle,
    this.variantLabel,
    this.onVariantTap,
    this.variantActionLabel,
    this.imageUrl,
    this.lineTotal,
    this.preliminary = false,
    this.pending = false,
    this.tone = CartLineTone.normal,
    this.message,
    this.messageIcon,
    this.actions = const <Widget>[],
    this.onOpen,
    this.onRemove,
    this.selected = false,
    this.dense = false,
    this.semanticLabel,
  });

  /// Название товара.
  final String title;

  /// «Хром · 1/2"».
  final String? variantLabel;

  /// Тап по подписи варианта — смена варианта (02 UI-20-007, `AppButton.text S` «Хром · 1/2" ›», CART-005);
  /// `null` — подпись только текстом.
  final VoidCallback? onVariantTap;

  /// Подпись действия для экранного диктора («Заменить вариант»).
  final String? variantActionLabel;

  /// «Арт. F4252 · 2 350 сом/шт».
  final String? subtitle;

  /// Миниатюра (thumb); `null` — заглушка.
  final String? imageUrl;

  /// Степпер количества (или «2 шт» в `readonly`).
  final Widget quantity;

  /// Сумма строки сервера; `null` — «—».
  final Money? lineTotal;

  /// Сумма не подтверждена сервером (изменение ещё не отправлено) — «≈» и `textSecondary`.
  final bool preliminary;

  /// Изменение отправляется — индикатор 16 у суммы.
  final bool pending;

  /// Предупреждение строки.
  final CartLineTone tone;

  /// Текст предупреждения («Цена изменилась: было 2 350 → стало 2 410 сом»).
  final String? message;

  /// Иконка предупреждения (по умолчанию — по [tone]).
  final IconData? messageIcon;

  /// Действия под предупреждением («Уменьшить до 3», «Удалить позицию»).
  final List<Widget> actions;

  /// Тап по фото/названию — карточка товара.
  final VoidCallback? onOpen;

  /// Крестик; `null` — скрыт (`readonly`) или недоступен.
  final VoidCallback? onRemove;

  /// «Удалить».
  final String removeLabel;

  /// Выбрана клавиатурой (↑/↓) — кольцо `focus` inset.
  final bool selected;

  /// expanded: название в одну строку, высота 64.
  final bool dense;

  /// «Смеситель Frap F4252, 2 штуки, 4 700 сом».
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool unavailable = tone == CartLineTone.unavailable;
    final Color bg = tone == CartLineTone.warning ? c.warningContainer : c.surface;
    final Color messageColor = switch (tone) {
      CartLineTone.warning => c.warning,
      CartLineTone.error => c.error,
      CartLineTone.unavailable || CartLineTone.normal => c.textSecondary,
    };
    final IconData icon =
        messageIcon ??
        switch (tone) {
          CartLineTone.warning => Icons.warning_amber_rounded,
          CartLineTone.error => Icons.error_outline_rounded,
          CartLineTone.unavailable => Icons.block_rounded,
          CartLineTone.normal => Icons.info_outline_rounded,
        };
    final Money? total = lineTotal;
    final TextStyle totalStyle = context.text
        .priceOf(context.text.bodyLg)
        .copyWith(color: preliminary || unavailable ? c.textSecondary : c.textPrimary);
    final Widget sum = SizedBox(
      width: 88,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          if (pending) ...<Widget>[const AppProgress.circular(size: 16), SizedBox(width: context.space.s1)],
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                // Финансовая сумма — 2 знака, как итоги корзины и строки SCR-21 (03 Q-108).
                total == null ? '—' : '${preliminary ? '≈ ' : ''}${PriceText.format(total, fixed2: true)}',
                maxLines: 1,
                style: totalStyle,
              ),
            ),
          ),
        ],
      ),
    );
    final Widget info = DsInteractive(
      onTap: onOpen,
      enabled: onOpen != null,
      builder: (BuildContext context, DsInteractionState st) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Opacity(
            opacity: unavailable ? 0.5 : 1,
            child: ProductImage(url: imageUrl, dimension: 48, borderRadius: BorderRadius.all(context.radii.sm)),
          ),
          SizedBox(width: context.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: dense ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body.copyWith(
                    fontWeight: FontWeight.w500,
                    color: unavailable ? c.textSecondary : c.textPrimary,
                    decoration: st.hovered ? TextDecoration.underline : null,
                  ),
                ),
                if (variantLabel != null)
                  if (onVariantTap == null && variantActionLabel == null)
                    Text(
                      variantLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.caption.copyWith(color: c.primaryText),
                    )
                  else
                    _VariantLink(label: variantLabel!, actionLabel: variantActionLabel, onTap: onVariantTap),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption.copyWith(
                      color: c.textSecondary,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final Widget body = Padding(
      padding: EdgeInsets.all(context.space.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: info),
              if (onRemove != null || removeLabel.isNotEmpty)
                AppIconButton(
                  icon: Icons.close_rounded,
                  iconSize: 20,
                  small: true,
                  semanticLabel: removeLabel,
                  onPressed: onRemove,
                ),
            ],
          ),
          SizedBox(height: context.space.s2),
          LayoutBuilder(
            // Узкая панель (overlay 320): степпер без отступа под миниатюрой.
            builder: (BuildContext context, BoxConstraints box) => Row(
              children: <Widget>[
                if (box.maxWidth >= 320) SizedBox(width: 48 + context.space.s3),
                quantity,
                const Spacer(),
                sum,
              ],
            ),
          ),
          if (message != null) ...<Widget>[
            SizedBox(height: context.space.s2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, size: 16, color: messageColor),
                SizedBox(width: context.space.s1),
                Expanded(
                  child: Text(message!, style: context.text.caption.copyWith(color: messageColor)),
                ),
              ],
            ),
          ],
          if (actions.isNotEmpty) Wrap(spacing: context.space.s2, children: actions),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            bottom: BorderSide(color: c.border),
            left: tone == CartLineTone.error ? BorderSide(color: c.error, width: 3) : BorderSide.none,
          ),
        ),
        foregroundDecoration: selected ? BoxDecoration(border: Border.all(color: c.focus, width: 2)) : null,
        child: body,
      ),
    );
  }
}

/// Подпись варианта как ссылка «Хром · 1/2" ›» (UI-20-007): цель нажатия ≥ 44 lp по высоте (A11Y-003),
/// disabled (`onTap == null`, офлайн) — `disabledText`.
class _VariantLink extends StatelessWidget {
  const _VariantLink({required this.label, required this.onTap, this.actionLabel});

  final String label;
  final String? actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: actionLabel == null ? label : '$label, $actionLabel',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey<String>('cart-line-variant'),
        onTap: onTap,
        borderRadius: BorderRadius.all(context.radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: 1,
            child: Text(
              '$label ›',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.caption.copyWith(
                color: enabled ? c.primaryText : c.disabledText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
