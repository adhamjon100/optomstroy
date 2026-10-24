import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Индикатор долга `ReceivableBadge.compact` в карточке клиента (03 §9.36, §9.37): только «есть долг» /
/// «просрочка» по флагам `hasDebt`/`isOverdue`, без сумм (ядро §22.13 п.1).
enum CustomerDebtIndicator { none, hasDebt, overdue }

/// Карточка клиента `CustomerCard` (03 §9.36), вариант `compact` (оформление/корзина, 72 lp): аватар 40 с
/// инициалами → имя `body 600` [+ чип «Ожидает 1С»] → телефон `caption tnum` → мета `caption textSecondary`
/// («История: 12 заказов · Долг: есть · Скидка: 5 %», строку собирает вызывающий код по роли) → крестик «снять».
/// Компонент не знает сущностей фич (FL-05): данные — готовыми строками.
class CustomerCard extends StatelessWidget {
  /// Карточка выбранного клиента.
  const CustomerCard.compact({
    super.key,
    required this.name,
    this.phone,
    this.meta,
    this.debt = CustomerDebtIndicator.none,
    this.debtLabel,
    this.pendingLabel,
    this.tooltip,
    this.onRemove,
    this.removeLabel,
    this.loading = false,
    this.errorText,
    this.onRetry,
    this.retryLabel,
  }) : _row = false,
       onTap = null,
       onLongPress = null,
       selected = false,
       trailing = null,
       priceListLabel = null,
       rowHeight = 72;

  /// Строка списка `CustomerCard.row` (SCR-31, SCR-40, SCR-30; 03 §9.36): аватар 40 → имя `body 500` [+ «ожидает 1С»]
  /// → телефон и код `caption tnum` → справа индикатор долга без суммы (`ReceivableBadge.compact`, задаёт вызывающий
  /// код в [trailing] вместе со звездой) и шеврон. Выбранная строка — полоса `primaryText` 3 + `primaryContainer`.
  /// Высота — 72 (compact) / 56 (medium) / 48 (expanded) по [rowHeight].
  const CustomerCard.row({
    super.key,
    required this.name,
    this.phone,
    this.meta,
    this.pendingLabel,
    this.priceListLabel,
    this.tooltip,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.trailing,
    this.rowHeight = 72,
    this.loading = false,
  }) : _row = true,
       debt = CustomerDebtIndicator.none,
       debtLabel = null,
       onRemove = null,
       removeLabel = null,
       errorText = null,
       onRetry = null,
       retryLabel = null;

  final bool _row;

  /// Тап по строке (SCR-32 / выбор в мастер-детали).
  final VoidCallback? onTap;

  /// Долгое нажатие / правый клик — контекстное меню строки.
  final VoidCallback? onLongPress;

  /// Выбрана в мастер-детали.
  final bool selected;

  /// Правая часть строки (индикатор долга, звезда).
  final Widget? trailing;

  /// Чип вида цены (`StatusChip.priceList`).
  final String? priceListLabel;

  /// Высота строки.
  final double rowHeight; // money-double: allow — геометрия UI (lp)

  /// Имя / наименование.
  final String name;

  /// Телефон (`+996 700 123 456` или маска — по роли).
  final String? phone;

  /// Мета-строка.
  final String? meta;

  /// Индикатор долга (без суммы).
  final CustomerDebtIndicator debt;

  /// Подпись индикатора («Есть долг» / «Просрочка»).
  final String? debtLabel;

  /// Чип `info` «Ожидает 1С» (клиент POS без `onec_ref`, CUST-014).
  final String? pendingLabel;

  /// Тултип (код 1С).
  final String? tooltip;

  /// «Снять клиента»; `null` — без крестика.
  final VoidCallback? onRemove;

  /// Подпись крестика для screen reader.
  final String? removeLabel;

  /// Скелетон.
  final bool loading;

  /// «Данные клиента устарели» (`warning`).
  final String? errorText;

  /// «Обновить».
  final VoidCallback? onRetry;

  /// Подпись «Обновить».
  final String? retryLabel;

  /// Высота строки `row` по классу окна: 72 (compact) / 56 (medium) / 48 (expanded, large) — 02 UI-31-003.
  static double rowHeightFor(WindowClass wc) => switch (wc) {
    WindowClass.compact => 72,
    WindowClass.medium => 56,
    _ => 48,
  };

  /// Инициалы (до двух букв).
  static String initials(String name) {
    final List<String> parts = name.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final String first = parts.first.characters.first;
    final String second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (_row) return _buildRow(context);
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    if (loading) {
      return Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: radius,
          border: Border.all(color: c.border),
        ),
        child: const Row(
          children: <Widget>[
            SkeletonBox.avatar(),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SkeletonBox.text(width: 160),
                  SizedBox(height: 6),
                  SkeletonBox.text(width: 220, height: 14),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final Widget body = Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: radius,
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.primaryContainer),
            child: Text(
              initials(name),
              style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryText),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                    ),
                    if (pendingLabel != null)
                      StatusChip(label: pendingLabel!, variant: StatusChipVariant.info, dense: true),
                    if (debt != CustomerDebtIndicator.none && debtLabel != null)
                      StatusChip(
                        label: debtLabel!,
                        variant: debt == CustomerDebtIndicator.overdue
                            ? StatusChipVariant.error
                            : StatusChipVariant.warning,
                        dense: true,
                      ),
                  ],
                ),
                if (phone != null)
                  Text(
                    phone!,
                    style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                  ),
                // «История · Долг · Скидка» в узкой колонке SCR-21 (expanded 1280) — до 3 строк, скидка не обрезается
                // (02 UI-21-005).
                if (meta != null)
                  Text(
                    meta!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption.copyWith(color: c.textSecondary),
                  ),
                if (errorText != null)
                  Row(
                    children: <Widget>[
                      Icon(Icons.schedule_rounded, size: 16, color: c.warning),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(errorText!, style: context.text.caption.copyWith(color: c.warning)),
                      ),
                      if (onRetry != null && retryLabel != null)
                        TextButton(onPressed: onRetry, child: Text(retryLabel!)),
                    ],
                  ),
              ],
            ),
          ),
          if (onRemove != null)
            AppIconButton(icon: Icons.close_rounded, onPressed: onRemove, semanticLabel: removeLabel ?? ''),
        ],
      ),
    );
    return Semantics(
      container: true,
      label: <String>[name, ?phone, ?meta].join(', '),
      child: tooltip == null ? body : Tooltip(message: tooltip, child: body),
    );
  }

  Widget _buildRow(BuildContext context) {
    final DsColors c = context.colors;
    final bool dense = rowHeight < 64;
    if (loading) {
      return SizedBox(
        height: rowHeight,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              SkeletonBox.avatar(),
              SizedBox(width: 12),
              Expanded(child: SkeletonBox.text(width: 200)),
            ],
          ),
        ),
      );
    }
    final TextStyle sub = context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric);
    final String secondLine = <String>[?phone, ?meta].join(' · ');
    return Semantics(
      container: true,
      button: onTap != null,
      selected: selected,
      label: <String>[name, ?pendingLabel, ?phone, ?meta].join(', '),
      child: DsInteractive(
        onTap: onTap,
        onLongPress: onLongPress,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = selected
              ? c.primaryContainer
              : (s.pressed ? c.surfacePressed : (s.hovered || s.focused ? c.surfaceHover : c.surface));
          final Widget row = Container(
            constraints: BoxConstraints(minHeight: rowHeight),
            decoration: BoxDecoration(
              color: bg,
              border: Border(
                left: BorderSide(color: selected ? c.primaryText : Colors.transparent, width: 3),
                bottom: BorderSide(color: c.border),
              ),
            ),
            padding: EdgeInsets.fromLTRB(13, dense ? 4 : 8, 8, dense ? 4 : 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: dense ? 32 : 40,
                  height: dense ? 32 : 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: c.primaryContainer),
                  child: ExcludeSemantics(
                    child: Text(
                      initials(name),
                      style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryText),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.body.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                            ),
                          ),
                          if (pendingLabel != null) ...<Widget>[
                            const SizedBox(width: 6),
                            StatusChip(label: pendingLabel!, variant: StatusChipVariant.warning, dense: true),
                          ],
                        ],
                      ),
                      if (secondLine.isNotEmpty || priceListLabel != null)
                        Wrap(
                          spacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            if (secondLine.isNotEmpty)
                              Text(secondLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: sub),
                            if (priceListLabel != null && !dense)
                              StatusChip(label: priceListLabel!, variant: StatusChipVariant.priceList, dense: true),
                          ],
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing!],
                if (onTap != null) Icon(Icons.chevron_right_rounded, size: 20, color: c.textTertiary),
              ],
            ),
          );
          return tooltip == null ? row : Tooltip(message: tooltip, child: row);
        },
      ),
    );
  }
}
