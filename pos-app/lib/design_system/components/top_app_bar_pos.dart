import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Варианты `TopAppBarPos` (03 §9.57).
enum TopAppBarVariant {
  /// medium/expanded/large: бургер · логотип · поиск · часы · синхронизация · уведомления · пользователь.
  full,

  /// compact 56: назад/логотип · заголовок или поиск · действия.
  compact,

  /// В листах/диалогах: заголовок + крестик.
  modal,

  /// Экран входа: логотип и переключатель языка.
  auth,
}

/// Шапка рабочего пространства `TopAppBarPos` (03 §9.57): `surface`, нижняя граница `border`,
/// `elevation.1`; высота 72 (expanded/large) / 64 (medium) / 56 (compact, modal). Содержимое —
/// слоты: логотип (`SplashLogo.header` — RM-D-007), `SearchBar.header`, часы, `SyncIndicator`,
/// `NotificationBell`, блок пользователя. Шапка закреплена; `Semantics(header)`.
class TopAppBarPos extends StatelessWidget implements PreferredSizeWidget {
  /// Создаёт шапку.
  const TopAppBarPos({
    super.key,
    this.variant = TopAppBarVariant.full,
    this.windowClass,
    this.title,
    this.logo,
    this.onMenu,
    this.menuLabel,
    this.leading,
    this.search,
    this.actions = const <Widget>[],
    this.user,
    this.onClose,
    this.closeLabel,
  });

  /// Вариант.
  final TopAppBarVariant variant;

  /// Класс окна для высоты `full` (по умолчанию — из `MediaQuery`).
  final WindowClass? windowClass;

  /// Заголовок (compact без поиска / modal).
  final String? title;

  /// Логотип.
  final Widget? logo;

  /// «Бургер» (сворачивает сайдбар на expanded / открывает drawer на medium).
  final VoidCallback? onMenu;

  /// Подпись «бургера».
  final String? menuLabel;

  /// «Назад» или иной элемент слева (compact).
  final Widget? leading;

  /// Поле поиска (`SearchBar.header` / `.compact`).
  final Widget? search;

  /// Элементы справа: часы, синхронизация, уведомления, сканер.
  final List<Widget> actions;

  /// Блок пользователя ([TopAppBarUser]).
  final Widget? user;

  /// Крестик (modal).
  final VoidCallback? onClose;

  /// Подпись крестика.
  final String? closeLabel;

  /// Высота по варианту и классу окна.
  static double heightFor(TopAppBarVariant v, WindowClass wc) => switch (v) {
    TopAppBarVariant.compact || TopAppBarVariant.modal => 56,
    TopAppBarVariant.auth => 64,
    TopAppBarVariant.full => switch (wc) {
      WindowClass.compact => 56,
      WindowClass.medium => 64,
      WindowClass.expanded || WindowClass.large => 72,
    },
  };

  @override
  Size get preferredSize => Size.fromHeight(heightFor(variant, windowClass ?? WindowClass.expanded));

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final WindowClass wc = windowClass ?? context.windowClass;
    final double height = heightFor(variant, wc);
    final double hPad = wc == WindowClass.compact ? 16 : 24;
    final List<Widget> children = switch (variant) {
      TopAppBarVariant.full => <Widget>[
        if (onMenu != null) ...<Widget>[
          AppIconButton(icon: Icons.menu_rounded, semanticLabel: menuLabel ?? '', onPressed: onMenu),
          const SizedBox(width: 8),
        ],
        if (logo != null) ...<Widget>[logo!, const SizedBox(width: 16)],
        if (search != null)
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(constraints: const BoxConstraints(minWidth: 320, maxWidth: 720), child: search),
            ),
          )
        else
          const Spacer(),
        for (final Widget a in actions) ...<Widget>[const SizedBox(width: 16), a],
        if (user != null) ...<Widget>[const SizedBox(width: 16), user!],
      ],
      TopAppBarVariant.compact => <Widget>[
        if (leading != null) ...<Widget>[leading!, const SizedBox(width: 8)] else if (logo != null) ...<Widget>[
          logo!,
          const SizedBox(width: 12),
        ],
        Expanded(
          child:
              search ??
              Semantics(
                header: true,
                child: Text(
                  title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.title.copyWith(color: c.textPrimary),
                ),
              ),
        ),
        for (final Widget a in actions) ...<Widget>[const SizedBox(width: 4), a],
      ],
      TopAppBarVariant.modal => <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.h3.copyWith(color: c.textPrimary),
            ),
          ),
        ),
        if (onClose != null)
          AppIconButton(icon: Icons.close_rounded, semanticLabel: closeLabel ?? '', onPressed: onClose),
      ],
      TopAppBarVariant.auth => <Widget>[?logo, const Spacer(), ...actions],
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: variant == TopAppBarVariant.modal ? 24 : hPad),
        decoration: BoxDecoration(
          color: c.surface,
          border: variant == TopAppBarVariant.auth ? null : Border(bottom: BorderSide(color: c.border)),
          boxShadow: variant == TopAppBarVariant.full || variant == TopAppBarVariant.compact
              ? context.elevation.e1
              : null,
        ),
        child: Row(children: children),
      ),
    );
  }
}

/// Часы шапки: «09:41» `bodyLg 600 tnum` + дата «сб, 18 окт» `caption textSecondary`.
/// Строки форматирует вызывающий код (`DsDateFormat`, Asia/Bishkek, раз в минуту).
class TopAppBarClock extends StatelessWidget {
  /// Создаёт часы.
  const TopAppBarClock({super.key, required this.time, required this.date});

  /// Время.
  final String time;

  /// Дата.
  final String date;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(
          time,
          style: context.text.bodyLg.copyWith(
            fontWeight: FontWeight.w600,
            color: c.textPrimary,
            fontFeatures: DsTypography.numeric,
          ),
        ),
        Text(date, style: context.text.caption.copyWith(color: c.textSecondary)),
      ],
    );
  }
}

/// Блок пользователя шапки: аватар-инициалы + имя `body 500` + роль `caption textSecondary`;
/// тап → меню (Профиль · Настройки · Выйти — у вызывающего кода). Читается «Абдулла, продавец».
class TopAppBarUser extends StatelessWidget {
  /// Создаёт блок.
  const TopAppBarUser({super.key, required this.name, required this.role, this.onTap, this.showText = true});

  /// Имя (из `/me`).
  final String name;

  /// Роль (`RoleBadge.text`).
  final String role;

  /// Открыть меню.
  final VoidCallback? onTap;

  /// Показывать имя и роль (на medium — только аватар).
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final String initials = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return Semantics(
      button: onTap != null,
      label: '$name, $role',
      excludeSemantics: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: BorderRadius.all(context.radii.sm),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: s.hovered ? c.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.all(context.radii.sm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
                  child: Text(
                    initials,
                    style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryText),
                  ),
                ),
                if (showText) ...<Widget>[
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(name, style: context.text.bodyMedium.copyWith(color: c.textPrimary)),
                      Text(role, style: context.text.caption.copyWith(color: c.textSecondary)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
