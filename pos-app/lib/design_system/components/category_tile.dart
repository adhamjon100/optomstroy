import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Плитка категории `CategoryTile` (03 §9.10; 02 UI-12-006, лист «Все категории» на compact/medium):
/// карточка 96×96…160×120 → изображение 1С или иконка 32 `primaryText` в круге 56 `primaryContainer`
/// → название `label 500` 2 строки → счётчик `caption`. Выбранная — обводка `primaryText` 2.
class CategoryTile extends StatelessWidget {
  /// Создаёт плитку.
  const CategoryTile({
    super.key,
    required this.label,
    required this.onTap,
    this.countLabel,
    this.imageUrl,
    this.iconKey,
    this.selected = false,
    this.semanticLabel,
  });

  /// Название.
  final String label;

  /// Открыть категорию.
  final VoidCallback? onTap;

  /// «124» / «124 товара».
  final String? countLabel;

  /// Изображение 1С.
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Текущая категория.
  final bool selected;

  /// «Смесители, 124 товаров» (`category_tile_a11y`).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) {
          final double scale = s.pressed && !context.motion.reduceMotion ? 0.98 : 1;
          return AnimatedScale(
            scale: scale,
            duration: context.motion.of(context.motion.fast),
            child: DsFocusRing(
              visible: s.focused,
              borderRadius: BorderRadius.all(context.radii.md),
              child: Container(
                constraints: const BoxConstraints(minWidth: 96, minHeight: 96),
                padding: EdgeInsets.all(context.space.s2),
                decoration: BoxDecoration(
                  color: s.pressed ? c.surfacePressed : c.surface,
                  borderRadius: BorderRadius.all(context.radii.md),
                  border: Border.all(color: selected ? c.primaryText : c.border, width: selected ? 2 : 1),
                  boxShadow: s.hovered ? context.elevation.e1 : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (hasImage)
                      CategoryImage(imageUrl: imageUrl, iconKey: iconKey, size: 56, iconSize: 32, color: c.primaryText)
                    else
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
                        child: Icon(CategoryIcons.of(iconKey), size: 32, color: c.primaryText),
                      ),
                    SizedBox(height: context.space.s2),
                    Text(
                      label,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.label.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                    ),
                    if (countLabel != null)
                      Text(
                        countLabel!,
                        maxLines: 1,
                        style: context.text.caption.copyWith(
                          color: c.textSecondary,
                          fontFeatures: DsTypography.numeric,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
