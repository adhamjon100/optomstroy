import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Пункт [NavigationDrawerApp].
@immutable
class NavigationDrawerItem {
  /// Создаёт пункт.
  const NavigationDrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selectedIcon,
    this.selected = false,
    this.key,
    this.trailing,
    this.semanticLabel,
  });

  /// Иконка (outlined).
  final IconData icon;

  /// Иконка выбранного пункта (filled); по умолчанию [icon].
  final IconData? selectedIcon;

  /// Подпись (строка ARB).
  final String label;

  /// Выбран (текущий раздел).
  final bool selected;

  /// Переход.
  final VoidCallback onTap;

  /// Ключ строки (тесты).
  final Key? key;

  /// Текст справа в строке — число («Избранное 12», ADR-114 п. 1: видимое число избранных перенесено сюда из колонки
  /// каталога); `null` — без него.
  final String? trailing;

  /// Подпись для screen reader («Избранное, 12 товаров»); `null` — [label].
  final String? semanticLabel;
}

/// Группа пунктов [NavigationDrawerApp]: необязательный заголовок + пункты.
@immutable
class NavigationDrawerGroup {
  /// Создаёт группу.
  const NavigationDrawerGroup({required this.items, this.title});

  /// Заголовок группы («Другие разделы»); `null` — без заголовка.
  final String? title;

  /// Пункты.
  final List<NavigationDrawerItem> items;
}

/// Drawer навигации оболочки сотрудника на medium и шире (03 §9.71; D3, ADR-112).
///
/// Ширина [DsBreakpoints.navDrawer] 320, фон `surface`, справа граница `border`. Сверху — [header] (логотип);
/// ниже — [groups]: заголовок группы `label 600 textSecondary`, строки 48 с иконкой 24 и подписью `body`; справа —
/// [NavigationDrawerItem.trailing] 12/600 (`catalogMeta`; при наведении и нажатии — `textSecondary`, у выбранного —
/// `onPrimaryContainer`: на этих фонах `catalogMeta` ниже 4,5:1, CP-124/125).
/// Выбранный пункт — фон `primaryContainer`, подпись `onPrimaryContainer 600`, залитая иконка и полоса 3 px
/// `primaryText` слева (признак не только цветом, A11Y-004). Вся панель — `Semantics`-группа [semanticLabel]
/// («Навигация»). Esc закрывает ([onClose]); затемнение и его тап — у `Scaffold.drawer`.
class NavigationDrawerApp extends StatelessWidget {
  /// Создаёт drawer.
  const NavigationDrawerApp({
    super.key,
    required this.groups,
    required this.semanticLabel,
    this.header,
    this.onClose,
    this.width = DsBreakpoints.navDrawer,
  });

  /// Группы пунктов (первая — вкладки режима, вторая — «Другие разделы»).
  final List<NavigationDrawerGroup> groups;

  /// Подпись области для screen reader (`shell_nav_a11y` «Навигация»).
  final String semanticLabel;

  /// Заголовок панели (логотип).
  final Widget? header;

  /// Закрыть drawer (Esc).
  final VoidCallback? onClose;

  /// Ширина панели.
  final double width;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final List<Widget> children = <Widget>[];
    for (int g = 0; g < groups.length; g++) {
      final NavigationDrawerGroup group = groups[g];
      if (group.items.isEmpty) {
        continue;
      }
      if (children.isNotEmpty) {
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.s2),
            child: Divider(height: 1, thickness: 1, color: c.border),
          ),
        );
      }
      if (group.title != null) {
        children.add(
          Padding(
            padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s2, context.space.s6, context.space.s1),
            child: Semantics(
              header: true,
              child: Text(
                group.title!,
                style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textSecondary),
              ),
            ),
          ),
        );
      }
      for (final NavigationDrawerItem item in group.items) {
        children.add(_DrawerRow(key: item.key, item: item));
      }
    }
    Widget panel = Material(
      color: c.surface,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: c.border)),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (header != null)
                Container(
                  height: DsBreakpoints.topBarHeight,
                  padding: EdgeInsets.symmetric(horizontal: context.space.s6),
                  alignment: AlignmentDirectional.centerStart,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.border)),
                  ),
                  child: header,
                ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.symmetric(vertical: context.space.s2),
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    panel = Semantics(
      container: true,
      explicitChildNodes: true,
      namesRoute: true,
      scopesRoute: true,
      label: semanticLabel,
      child: panel,
    );
    final VoidCallback? close = onClose;
    if (close == null) {
      return panel;
    }
    // Esc закрывает drawer: фокус переходит внутрь панели (autofocus), сочетание обрабатывается здесь.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{const SingleActivator(LogicalKeyboardKey.escape): close},
      child: Focus(autofocus: true, skipTraversal: true, child: panel),
    );
  }
}

class _DrawerRow extends StatelessWidget {
  const _DrawerRow({super.key, required this.item});

  final NavigationDrawerItem item;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool selected = item.selected;
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    final String? trailing = item.trailing;
    return Semantics(
      button: true,
      selected: selected,
      label: item.semanticLabel ?? item.label,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: item.onTap,
      child: DsInteractive(
        onTap: item.onTap,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = selected
              ? c.primaryContainer
              : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : Colors.transparent));
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s3),
            child: DsFocusRing(
              visible: s.focused,
              borderRadius: radius,
              child: Container(
                height: 48,
                decoration: BoxDecoration(color: bg, borderRadius: radius),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  children: <Widget>[
                    // Полоса 3 px `primaryText` у выбранного пункта — индикатор формы (A11Y-004).
                    Container(width: 3, color: selected ? c.primaryText : Colors.transparent),
                    SizedBox(width: context.space.s3 - 3),
                    Icon(
                      selected ? (item.selectedIcon ?? item.icon) : item.icon,
                      size: 24,
                      color: selected ? c.primaryText : c.textSecondary,
                    ),
                    SizedBox(width: context.space.s4),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.body.copyWith(
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          color: selected ? c.onPrimaryContainer : c.textPrimary,
                        ),
                      ),
                    ),
                    if (trailing != null) ...<Widget>[
                      SizedBox(width: context.space.s2),
                      Text(
                        trailing,
                        key: const ValueKey<String>('nav-drawer-item-trailing'),
                        maxLines: 1,
                        style: context.text.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? c.onPrimaryContainer
                              : (s.pressed || s.hovered ? c.textSecondary : c.catalogMeta),
                        ),
                      ),
                    ],
                    SizedBox(width: context.space.s3),
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
