// `ShiftSummaryCard` — сводка смены «Сегодня» SCR-30 (02 UI-30-014; составной компонент из `PriceText` (kpi) ×3 и
// строки счётчиков; в 03 §9 отдельного имени нет — GQ-FECASH-03): три плитки в ряд «Наличные» · «QR» · «В долг»
// (`surfaceVariant`, `ds.radius.md`; сумма `h3 700 tnum`, подпись `caption textSecondary`), под ними
// «Заказов: N · Платежей: M». Суммы — только с сервера (`PosDashboard.totals`), клиент их не вычисляет.
// Тап по плитке — переход в журнал с фильтром способа (у вызывающего кода). Загрузка — скелетоны.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
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
        Row(
          children: <Widget>[
            for (int i = 0; i < tiles.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: context.space.s2),
              Expanded(
                child: _Tile(tile: tiles[i], loading: loading),
              ),
            ],
          ],
        ),
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
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.loading});

  final ShiftSummaryTile tile;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final String amount = PriceText.format(tile.amount, fixed2: true);
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                tile.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.caption.copyWith(color: c.textSecondary),
              ),
              SizedBox(height: context.space.s1),
              if (loading)
                const SkeletonBox.text(width: 72)
              else
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: AnimatedSwitcher(
                    duration: context.motion.of(context.motion.base),
                    child: Text(
                      amount,
                      key: ValueKey<int>(tile.amount.tyiyn),
                      maxLines: 1,
                      style: context.text.h3.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontFeatures: DsTypography.numeric,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
