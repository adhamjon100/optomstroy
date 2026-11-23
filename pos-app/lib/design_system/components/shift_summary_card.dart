// `ShiftSummaryCard` — сводка смены «Сегодня» SCR-30 (02 UI-30-014; составной компонент из `PriceText` (kpi) ×3 и
// строки счётчиков; в 03 §9 отдельного имени нет — GQ-FECASH-03): три плитки в ряд «Наличные» · «QR» · «В долг»
// (`surfaceVariant`, `ds.radius.md`; сумма `h3 700 tnum`, подпись `caption textSecondary`), под ними
// «Заказов: N · Платежей: M». Суммы — только с сервера (`PosDashboard.totals`), клиент их не вычисляет.
// Тап по плитке — переход в журнал с фильтром способа (у вызывающего кода). Загрузка — скелетоны.
// Суммы не уменьшаются как обычный вид (03 §8.8; 02 UI-30-014 «3 плитки в ряд, если суммы помещаются без уменьшения;
// иначе — столбиком»; указание владельца 2026-11-18, 15 §5.8 (3) — [ВЫВОД исполнителя]): ширина самой длинной суммы
// (`h3 700 tnum` с масштабом текста окна) + поля плитки измеряется; не помещаются три в ряд — плитки столбиком во всю
// ширину, каждая — строкой «подпись слева, сумма справа», а если и так тесно — прежней анатомией (подпись над суммой).
// Уменьшение `FittedBox` осталось только защитой для очень узкой ширины.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Плитка сводки.
@immutable
final class ShiftSummaryTile {
  /// Создаёт плитку.
  const ShiftSummaryTile({required this.label, required this.amount, this.onTap, this.key});

  /// «Наличные».
  final String label;

  /// Сумма за день.
  final Money amount;

  /// Переход в журнал.
  final VoidCallback? onTap;

  /// Ключ (тесты).
  final Key? key;
}

/// Сводка смены.
class ShiftSummaryCard extends StatelessWidget {
  /// Создаёт сводку.
  const ShiftSummaryCard({
    super.key,
    required this.title,
    required this.tiles,
    this.footer,
    this.loading = false,
    this.trailing,
  });

  /// «Сегодня».
  final String title;

  /// Плитки (обычно 3).
  final List<ShiftSummaryTile> tiles;

  /// «Заказов: 12 · Платежей: 9».
  final String? footer;

  /// Скелетоны вместо сумм.
  final bool loading;

  /// Элемент справа от заголовка (метка «обновлено 09:42»).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: AppSectionHeader(title: title, padding: EdgeInsets.zero),
            ),
            ?trailing,
          ],
        ),
        SizedBox(height: context.space.s3),
        LayoutBuilder(builder: (BuildContext context, BoxConstraints box) => _tiles(context, box.maxWidth)),
        if (footer != null) ...<Widget>[
          SizedBox(height: context.space.s2),
          Text(
            footer!,
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
          ),
        ],
      ],
    );
  }

  /// Стиль суммы плитки (`h3 700 tnum`).
  static TextStyle amountStyle(BuildContext context) => context.text.h3.copyWith(
    color: context.colors.textPrimary,
    fontWeight: FontWeight.w700,
    fontFeatures: DsTypography.numeric,
  );

  Widget _tiles(BuildContext context, double maxWidth) {
    final double pad = context.space.s3; // money-double: allow — геометрия UI (lp)
    final double gap = context.space.s2; // money-double: allow — геометрия UI (lp)
    final TextStyle amount = amountStyle(context);
    final TextStyle label = context.text.caption;
    double need = 0; // money-double: allow — геометрия UI (lp)
    double labels = 0; // money-double: allow — геометрия UI (lp)
    for (final ShiftSummaryTile t in tiles) {
      need = math.max(need, dsTextWidth(context, PriceText.format(t.amount, fixed2: true), amount) + 2 * pad);
      labels = math.max(labels, dsTextWidth(context, t.label, label));
    }
    if (tiles.length * need + (tiles.length - 1) * gap <= maxWidth) {
      return Row(
        children: <Widget>[
          for (int i = 0; i < tiles.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: gap),
            Expanded(
              child: _Tile(tile: tiles[i], loading: loading),
            ),
          ],
        ],
      );
    }
    final bool inline = labels + gap + need <= maxWidth;
    return Column(
      key: stackedKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < tiles.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          _Tile(tile: tiles[i], loading: loading, inline: inline),
        ],
      ],
    );
  }

  /// Плитки столбиком (суммы не помещаются три в ряд без уменьшения).
  static const Key stackedKey = ValueKey<String>('shift-summary-stacked');
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.loading, this.inline = false});

  final ShiftSummaryTile tile;
  final bool loading;

  /// Строка во всю ширину: подпись слева, сумма справа.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final String amount = PriceText.format(tile.amount, fixed2: true);
    final Widget label = Text(
      tile.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.text.caption.copyWith(color: c.textSecondary),
    );
    // Защита для очень узкой ширины: обычно сумма помещается целиком (раскладку выбирает [ShiftSummaryCard]).
    final Widget value = loading
        ? const SkeletonBox.text(width: 72)
        : FittedBox(
            fit: BoxFit.scaleDown,
            alignment: inline ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
            child: AnimatedSwitcher(
              duration: context.motion.of(context.motion.base),
              child: Text(
                amount,
                key: ValueKey<int>(tile.amount.tyiyn),
                maxLines: 1,
                style: ShiftSummaryCard.amountStyle(context),
              ),
            ),
          );
    return Semantics(
      button: tile.onTap != null,
      label: '${tile.label}: ${PriceText.spoken(tile.amount)}',
      excludeSemantics: true,
      child: DsInteractive(
        key: tile.key,
        onTap: loading ? null : tile.onTap,
        enabled: tile.onTap != null && !loading,
        builder: (BuildContext context, DsInteractionState s) => AnimatedContainer(
          duration: context.motion.of(context.motion.fast),
          padding: EdgeInsets.all(context.space.s3),
          decoration: BoxDecoration(
            color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surfaceVariant),
            borderRadius: BorderRadius.all(context.radii.md),
          ),
          child: inline
              ? Row(
                  children: <Widget>[
                    Expanded(child: label),
                    SizedBox(width: context.space.s2),
                    value,
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    label,
                    SizedBox(height: context.space.s1),
                    value,
                  ],
                ),
        ),
      ),
    );
  }
}
