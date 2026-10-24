import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Иконки категорий по `iconKey` (03 §14.4): глиф Material Symbols → ближайший глиф `Icons`;
/// неизвестный ключ и `null` — `category`.
abstract final class CategoryIcons {
  /// Глиф по ключу.
  static IconData of(String? key) => switch (key) {
    'plumbing' || 'valve' => Icons.plumbing_rounded,
    'bathtub' => Icons.bathtub_rounded,
    'heat' || 'thermostat' => Icons.thermostat_rounded,
    'water_drop' => Icons.water_drop_rounded,
    'electrical_services' => Icons.electrical_services_rounded,
    'grid_on' => Icons.grid_on_rounded,
    'hardware' => Icons.hardware_rounded,
    'water_damage' => Icons.water_damage_rounded,
    'star' => Icons.star_rounded,
    'history' => Icons.history_rounded,
    _ => Icons.category_rounded,
  };
}

/// Изображение категории из 1С (Q-022) или иконка по `iconKey`, иначе `category` (CAT-009):
/// поле [size] на `surfaceVariant`; ошибка загрузки — та же иконка, фото товара не подставляется.
class CategoryImage extends StatelessWidget {
  /// Создаёт изображение.
  const CategoryImage({super.key, this.imageUrl, this.iconKey, this.size = 32, this.iconSize = 24, this.color});

  /// URL изображения категории (`thumb`).
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Сторона поля.
  final double size;

  /// Размер иконки.
  final double iconSize;

  /// Цвет иконки (по умолчанию `textSecondary`).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Widget icon = Center(
      key: const ValueKey<String>('category-image-icon'),
      child: Icon(CategoryIcons.of(iconKey), size: iconSize, color: color ?? c.textSecondary),
    );
    final String? url = imageUrl;
    final Widget content;
    if (url == null || url.isEmpty) {
      content = icon;
    } else {
      final ImageProvider<Object> provider = (ProductImageScope.maybeOf(context) ?? CachedNetworkImageProvider.new)(
        url,
      );
      content = Image(
        image: ResizeImage.resizeIfNeeded(ProductImage.cacheWidthOf(ProductImageSize.thumb), null, provider),
        width: size,
        height: size,
        fit: BoxFit.cover,
        frameBuilder: (BuildContext context, Widget child, int? frame, bool sync) {
          if (sync) {
            return child;
          }
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: context.motion.of(const Duration(milliseconds: 200)),
            child: child,
          );
        },
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) => icon,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.all(context.radii.sm),
      child: Container(width: size, height: size, color: c.surfaceVariant, child: content),
    );
  }
}

/// Вариант `CategorySidebarItem` (03 §9.8).
enum CategorySidebarItemVariant {
  /// Корневой пункт: изображение 32, `body 500`.
  root,

  /// Подкатегория: отступ +24, изображение 24, `body 400`.
  child,

  /// «★ Избранное 27» — отдельная карточка.
  favorites,
}

/// Пункт меню категорий `CategorySidebarItem` (03 §9.8; 02 UI-10-009): строка-карточка 52
/// (48 при compact-плотности) → изображение/иконка → название → счётчик-пилюля → [шеврон].
/// Выбранный — `primaryContainer` + полоса 3 lp `primaryText` + текст `primaryText 600`.
/// Повторный тап по выбранному — без действия (03 §9.8). Свёрнутый сайдбар (72) — [collapsed].
class CategorySidebarItem extends StatelessWidget {
  /// Создаёт пункт.
  const CategorySidebarItem({
    super.key,
    required this.label,
    required this.onTap,
    this.count,
    this.variant = CategorySidebarItemVariant.root,
    this.imageUrl,
    this.iconKey,
    this.selected = false,
    this.hasChildren = false,
    this.expanded = false,
    this.onToggleExpanded,
    this.collapsed = false,
    this.dense = false,
    this.semanticLabel,
    this.expandLabel,
  });

  /// Название.
  final String label;

  /// Открыть категорию (SCR-12).
  final VoidCallback? onTap;

  /// Счётчик товаров (`productCount`); `null` — без счётчика.
  final int? count;

  /// Вариант.
  final CategorySidebarItemVariant variant;

  /// Изображение 1С.
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Выбран.
  final bool selected;

  /// Есть подкатегории (шеврон).
  final bool hasChildren;

  /// Подкатегории раскрыты.
  final bool expanded;

  /// Шеврон.
  final VoidCallback? onToggleExpanded;

  /// Свёрнутый сайдбар 72: только изображение + точка-счётчик.
  final bool collapsed;

  /// Высота 48 (compact-плотность) вместо 52.
  final bool dense;

  /// «Смесители, 124 товара».
  final String? semanticLabel;

  /// Подпись шеврона для screen reader.
  final String? expandLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool isChild = variant == CategorySidebarItemVariant.child;
    final bool isFav = variant == CategorySidebarItemVariant.favorites;
    final double height = isChild ? 48 : (dense ? 48 : 52);
    final Widget image = isFav
        ? SizedBox.square(
            dimension: 32,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Icon(Icons.star_rounded, size: 24, color: c.favorite),
                  Icon(Icons.star_border_rounded, size: 24, color: c.warning),
                ],
              ),
            ),
          )
        : CategoryImage(
            imageUrl: imageUrl,
            iconKey: iconKey,
            size: isChild ? 24 : 32,
            iconSize: isChild ? 18 : 24,
            color: selected ? c.primaryText : null,
          );
    return Semantics(
      button: true,
      selected: selected,
      expanded: hasChildren ? expanded : null,
      label: semanticLabel ?? (count == null ? label : '$label, $count'),
      excludeSemantics: true,
      child: _MaybeTooltip(
        message: collapsed ? (semanticLabel ?? label) : null,
        child: DsInteractive(
          onTap: selected ? null : onTap,
          enabled: onTap != null,
          builder: (BuildContext context, DsInteractionState s) {
            final Color bg = selected
                ? c.primaryContainer
                : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface));
            final Widget row = collapsed
                ? Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        image,
                        if ((count ?? 0) > 0)
                          PositionedDirectional(
                            top: -2,
                            end: -2,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: c.primaryText, shape: BoxShape.circle),
                            ),
                          ),
                      ],
                    ),
                  )
                : Row(
                    children: <Widget>[
                      image,
                      SizedBox(width: context.space.s3),
                      // Длинное название — в 2 строки, а не обрезка на первом слове (FIX-EF-13).
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.body.copyWith(
                            color: selected ? c.primaryText : c.textPrimary,
                            fontWeight: selected ? FontWeight.w600 : (isChild ? FontWeight.w400 : FontWeight.w500),
                          ),
                        ),
                      ),
                      if (count != null) ...<Widget>[SizedBox(width: context.space.s2), _CountPill(count: count!)],
                      if (hasChildren)
                        Semantics(
                          button: true,
                          label: expandLabel,
                          child: InkResponse(
                            onTap: onToggleExpanded,
                            radius: 20,
                            child: SizedBox.square(
                              dimension: 32,
                              child: AnimatedRotation(
                                turns: expanded ? 0.5 : 0,
                                duration: context.motion.of(context.motion.base),
                                child: Icon(Icons.expand_more_rounded, size: 20, color: c.textSecondary),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
            return DsFocusRing(
              visible: s.focused,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  color: bg,
                  border: selected ? Border(left: BorderSide(color: c.primaryText, width: 3)) : null,
                ),
                padding: EdgeInsetsDirectional.only(
                  start: collapsed ? 0 : (isChild ? context.space.s3 + 24 : context.space.s3) - (selected ? 3 : 0),
                  end: collapsed ? 0 : context.space.s2,
                ),
                child: row,
              ),
            );
          },
        ),
      ),
    );
  }

  /// Скелетон пункта (loading): `SkeletonBox` 32×32 + строка 60 % + пилюля 32.
  static Widget skeleton(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s3),
      child: Row(
        children: <Widget>[
          const SkeletonBox(width: 32, height: 32),
          SizedBox(width: context.space.s3),
          const Expanded(
            child: FractionallySizedBox(
              widthFactor: 0.6,
              alignment: AlignmentDirectional.centerStart,
              child: SkeletonBox.text(height: 14),
            ),
          ),
          SizedBox(width: context.space.s2),
          const SkeletonBox(width: 32, height: 20),
        ],
      ),
    ),
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.space.s2, vertical: 2),
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.full)),
      child: Text(
        '$count',
        style: context.text.label.copyWith(
          color: count == 0 ? c.textTertiary : c.textSecondary,
          fontWeight: FontWeight.w500,
          fontFeatures: DsTypography.numeric,
        ),
      ),
    );
  }
}

class _MaybeTooltip extends StatelessWidget {
  const _MaybeTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) => message == null ? child : Tooltip(message: message, child: child);
}
