import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Шапка телефона `PhoneTopBar` (compact < 600 lp; 03 §9.57.1; 15 ADR-122; 02 §3.1 п. 8): шапка утверждённого
/// прототипа, собранная для телефона, — у всех ролей на основных экранах режима (корни веток `BottomNavBar`).
///
/// Только визуал и раскладка: данные и действия передаёт вызывающий (шапка каталога, шапка оболочки, SCR-50).
/// Слева направо: логотип [logo] (знак; цель касания [DsSpacing.s9] 48 вокруг знака, нажатие — [onLogo]) → поле
/// поиска [search] (`SearchBar.compact` со сканером у сотрудника) → [actions] (кнопка корзины с числом позиций,
/// `SyncIndicator` иконкой) → [bell] (`NotificationBell` со счётчиком) → [user] (аватар с инициалами, крайний справа).
/// Высота строки — как у `TopAppBarPos.compact` (56), фон `surface`, нижняя граница `border`, тень `elevation.1`;
/// поля по горизонтали — `space.4`, зазоры правой группы — `space.1`.
///
/// Поле поиска стоит в первой строке, если ему остаётся не меньше [TopAppBarPos.searchMinWidth] (240) после логотипа
/// и правой группы (цели касания по 48 — элементы правой группы на compact только иконками); иначе — второй строкой
/// на всю ширину ([searchRowKey], высота [TopAppBarPos.searchRowHeight] 56). На телефоне в портрете (320–480 lp)
/// поле всегда второй строкой; в ландшафте шириной до 600 lp — обычно в первой. Строка не переполняется: элементы
/// правой группы — фиксированной ширины, поле поиска — гибкое. Верхний системный отступ окна шапка берёт на себя
/// (`SafeArea(bottom: false)`, фон — под статус-баром); тело под шапкой отступа уже не получает (`AdaptiveScaffold`).
class PhoneTopBar extends StatelessWidget {
  /// Создаёт шапку телефона.
  const PhoneTopBar({
    super.key,
    required this.logo,
    this.onLogo,
    this.logoLabel,
    this.search,
    this.actions = const <Widget>[],
    this.bell,
    this.user,
  });

  /// Знак логотипа (без своего нажатия).
  final Widget logo;

  /// Нажатие на логотип — главный экран режима; `null` — логотип не нажимается.
  final VoidCallback? onLogo;

  /// Подпись логотипа для screen reader.
  final String? logoLabel;

  /// Поле поиска; `null` — шапка без поиска (одна строка).
  final Widget? search;

  /// Элементы правой группы до колокольчика (корзина, синхронизация).
  final List<Widget> actions;

  /// Колокольчик уведомлений.
  final Widget? bell;

  /// Аватар пользователя — крайний справа.
  final Widget? user;

  /// Ключ второй строки шапки с полем поиска (тесты).
  static const Key searchRowKey = ValueKey<String>('phone-top-bar-search-row');

  /// Ключ первой строки (тесты).
  static const Key rowKey = ValueKey<String>('phone-top-bar-row');

  /// Ключ цели касания логотипа (тесты).
  static const Key logoKey = ValueKey<String>('phone-top-bar-logo');

  /// Поле поиска помещается в первую строку шириной [width] (вся ширина шапки) при [trailing] элементах справа.
  static bool searchInline(BuildContext context, double width, int trailing) {
    final double target = context.space.s9; // money-double: allow — геометрия UI (lp)
    final double gap = context.space.s1; // money-double: allow — геометрия UI (lp)
    final double inner = width - 2 * context.space.s4; // money-double: allow — геометрия UI (lp)
    final double fixed = target + context.space.s3 + trailing * (target + gap); // money-double: allow — геометрия UI
    return inner - fixed >= TopAppBarPos.searchMinWidth;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final double rowHeight = TopAppBarPos.heightFor(TopAppBarVariant.compact, WindowClass.compact);
    final List<Widget> trailing = <Widget>[...actions, ?bell, ?user];
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.border)),
          boxShadow: context.elevation.e1,
        ),
        // Верхний системный отступ (статус-бар, вырез) — внутри шапки: фон `surface` уходит под статус-бар, элементы
        // строки — ниже него. Если шапка уже внутри `SafeArea` (SCR-10, SCR-50), отступ равен нулю.
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool inline = search != null && searchInline(context, constraints.maxWidth, trailing.length);
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    key: rowKey,
                    height: rowHeight,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: context.space.s4),
                      child: Row(
                        children: <Widget>[
                          _logo(context),
                          SizedBox(width: context.space.s3),
                          Expanded(
                            child: inline
                                ? Align(alignment: AlignmentDirectional.centerStart, child: search)
                                : const SizedBox.shrink(),
                          ),
                          for (final Widget a in trailing) ...<Widget>[SizedBox(width: context.space.s1), a],
                        ],
                      ),
                    ),
                  ),
                  if (search != null && !inline)
                    SizedBox(
                      key: searchRowKey,
                      height: TopAppBarPos.searchRowHeight,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(context.space.s4, 0, context.space.s4, context.space.s1),
                        child: Align(alignment: AlignmentDirectional.topStart, child: search),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _logo(BuildContext context) {
    final double target = context.space.s9; // money-double: allow — геометрия UI (lp)
    final Widget mark = SizedBox.square(
      key: logoKey,
      dimension: target,
      child: Center(child: logo),
    );
    final VoidCallback? tap = onLogo;
    if (tap == null) {
      return mark;
    }
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    return Semantics(
      button: true,
      label: logoLabel,
      excludeSemantics: logoLabel != null,
      onTap: tap,
      child: DsInteractive(
        onTap: tap,
        builder: (BuildContext context, DsInteractionState s) =>
            DsFocusRing(visible: s.focused, borderRadius: radius, child: mark),
      ),
    );
  }
}
