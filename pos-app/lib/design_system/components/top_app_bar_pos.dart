import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Варианты `TopAppBarPos` (03 §9.57).
enum TopAppBarVariant {
  /// medium/expanded/large (ADR-112): «бургер» · логотип · поиск · действия (синхронизация, корзина, часы) ·
  /// уведомления · пользователь.
  full,

  /// compact 56: назад/логотип · заголовок или поиск · действия.
  compact,

  /// В листах/диалогах: заголовок + крестик.
  modal,

  /// Экран входа: логотип и переключатель языка.
  auth,
}

/// Подпись пользователя у аватара на ступени сжатия шапки ([TopAppBarFit.user]).
enum TopAppBarUserFit {
  /// Имя и роль (не шире [TopAppBarUser.textMaxWidth]).
  full,

  /// Только имя, не шире [TopAppBarUser.nameShortMaxWidth]; роль — в меню аватара и `Semantics`.
  short,

  /// Только аватар.
  none,
}

/// Дата часов шапки на ступени сжатия ([TopAppBarFit.date]).
enum TopAppBarDateFit {
  /// Дата вызывающего (на ветке «Касса» — полная «Чт, 22 октября 2026»).
  full,

  /// Короткая «чт, 22 окт» ([TopAppBarClock.shortDate]); полная — в тултипе и `Semantics`.
  short,

  /// Только время; дата — в тултипе и `Semantics`.
  none,
}

/// Ступень сжатия шапки `TopAppBarPos.full` (02 §3.1 п. 7, ADR-112 «паритет функций, раунд 2»): шапка сжимается по
/// доступной ширине, а не по классу окна. Поле поиска — главный элемент: ему нужно не меньше
/// [TopAppBarPos.searchMinWidth], а пока у аватара видны имя или роль — не меньше [TopAppBarPos.searchComfortWidth]
/// (имя не сжимает поле до минимума; QA паритета функций, ADR-112); если не хватает, по очереди сворачивается
/// необязательное (см. [ladder]). Время, итог корзины, `SyncIndicator`, колокольчик, аватар и «бургер» не скрываются
/// никогда.
///
/// Элементы шапки читают ступень через [TopAppBarFit.of] (`TopAppBarCartButton`, [TopAppBarClock],
/// [TopAppBarUser], логотип); вне шапки — [TopAppBarFit.full] (ничего не свёрнуто).
@immutable
class TopAppBarFit {
  /// Создаёт ступень.
  const TopAppBarFit({
    this.cartLabel = true,
    this.user = TopAppBarUserFit.full,
    this.wordmark = true,
    this.date = TopAppBarDateFit.full,
    this.tight = false,
    this.searchBelow = false,
    this.logo = true,
  });

  /// Ничего не свёрнуто.
  static const TopAppBarFit full = TopAppBarFit();

  /// Строка «Корзина» над итогом кнопки-итога (свёрнута — итог одной строкой; число позиций и единицы — в тултипе и
  /// `Semantics` всегда).
  final bool cartLabel;

  /// Имя и роль у аватара.
  final TopAppBarUserFit user;

  /// «Оптомстрой» рядом со знаком логотипа.
  final bool wordmark;

  /// Дата под временем.
  final TopAppBarDateFit date;

  /// Узкие зазоры: 12 вместо 24 у поля поиска, 8 вместо 14 в правой группе.
  final bool tight;

  /// Поле поиска — второй строкой шапки (на всю ширину, до 680): в одной строке ему не хватает
  /// [TopAppBarPos.searchMinWidth] даже после всех сворачиваний.
  final bool searchBelow;

  /// Знак логотипа (последняя ступень: главный экран — и в drawer навигации по «бургеру»).
  final bool logo;

  /// Сворачивание сведений по порядку: роль (сокращённое имя) → имя (только аватар) → «Оптомстрой» (только знак) →
  /// строка «Корзина» кнопки-итога → полная дата «Касса» → короткая → дата (только время). Дата — последней: часы и
  /// дата — требования UI-10-005, UI-10-032, UI-30-013; имя и роль есть в заголовке меню аватара и в `Semantics`.
  /// Строка «Корзина» (ADR-114: всегда «Корзина», как в прототипе; единицы — в тултипе) почти не шире итога
  /// («0,00 сом»), поэтому сворачивается после «Оптомстрой»: в окне 1024 кнопка-итог остаётся как в прототипе
  /// (ревью RV-10).
  static const List<TopAppBarFit> _info = <TopAppBarFit>[
    TopAppBarFit(),
    TopAppBarFit(user: TopAppBarUserFit.short),
    TopAppBarFit(user: TopAppBarUserFit.none),
    TopAppBarFit(user: TopAppBarUserFit.none, wordmark: false),
    TopAppBarFit(cartLabel: false, user: TopAppBarUserFit.none, wordmark: false),
    TopAppBarFit(cartLabel: false, user: TopAppBarUserFit.none, wordmark: false, date: TopAppBarDateFit.short),
    TopAppBarFit(cartLabel: false, user: TopAppBarUserFit.none, wordmark: false, date: TopAppBarDateFit.none),
  ];

  /// Ступени по порядку: каждая ступень сведений [_info] — с обычными, затем с узкими зазорами (сведения важнее
  /// воздуха); всё это — с полем поиска в строке, затем — с полем второй строкой; последняя — без знака логотипа.
  /// Выбирается первая ступень, на которой всё помещается (`_RenderTopAppBarFit`).
  static final List<TopAppBarFit> ladder = <TopAppBarFit>[
    for (final bool below in <bool>[false, true])
      for (final TopAppBarFit f in _info)
        for (final bool tight in <bool>[false, true]) f._with(tight: tight, searchBelow: below),
    _info.last._with(tight: true, searchBelow: true, logo: false),
  ];

  /// Ступени шапки без поля поиска: второй строки нет.
  static final List<TopAppBarFit> ladderNoSearch = <TopAppBarFit>[
    for (final TopAppBarFit f in _info)
      for (final bool tight in <bool>[false, true]) f._with(tight: tight, searchBelow: false),
    _info.last._with(tight: true, searchBelow: false, logo: false),
  ];

  TopAppBarFit _with({required bool tight, required bool searchBelow, bool logo = true}) => TopAppBarFit(
    cartLabel: cartLabel,
    user: user,
    wordmark: wordmark,
    date: date,
    tight: tight,
    searchBelow: searchBelow,
    logo: logo,
  );

  /// Ступень ближайшей шапки `full`; вне неё — [full].
  static TopAppBarFit of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TopAppBarFitScope>()?.fit ?? full;

  @override
  bool operator ==(Object other) =>
      other is TopAppBarFit &&
      other.cartLabel == cartLabel &&
      other.user == user &&
      other.wordmark == wordmark &&
      other.date == date &&
      other.tight == tight &&
      other.searchBelow == searchBelow &&
      other.logo == logo;

  @override
  int get hashCode => Object.hash(cartLabel, user, wordmark, date, tight, searchBelow, logo);

  @override
  String toString() =>
      'TopAppBarFit(cartLabel: $cartLabel, user: ${user.name}, wordmark: $wordmark, date: ${date.name}, '
      'tight: $tight, searchBelow: $searchBelow, logo: $logo)';
}

class _TopAppBarFitScope extends InheritedWidget {
  const _TopAppBarFitScope({required this.fit, required super.child});

  final TopAppBarFit fit;

  @override
  bool updateShouldNotify(_TopAppBarFitScope oldWidget) => fit != oldWidget.fit;
}

/// Шапка рабочего пространства `TopAppBarPos` (03 §9.57; прототип 2026-10-29, ADR-112).
///
/// `full` (medium+): высота [fullHeight] 69 — 12 + 44 + 12 и нижняя граница 1 px `border` (прототип без округления,
/// ADR-114 п. 6), фон `surface`, без тени; поля по горизонтали 24 (16 на medium); элементы 44 стоят по центру
/// строки, их цели касания 48 помещаются в высоту шапки. Слева — «бургер» [onMenu] (drawer навигации
/// оболочки), логотип [logo] (знак 38 + «Оптомстрой» — у вызывающего), зазор 24, поле поиска [search] — от
/// логотипа, растёт до [searchMaxWidth] 680; справа группа с зазором 14: [actions] (`SyncIndicator`,
/// `TopAppBarCartButton`, часы [TopAppBarClock] — у сотрудника) → [bell] → [user].
/// Сжатие по доступной ширине ([TopAppBarFit], ADR-112 «паритет функций, раунд 2»): полю поиска — не меньше
/// [searchMinWidth] 240 (пока видны имя или роль у аватара — [searchComfortWidth] 320); если не хватает, по очереди
/// сворачиваются роль, имя, «Оптомстрой», строка «Корзина»,
/// дата (на «Кассе» — сначала до короткой), затем зазоры 24/14 → 12/8; если и так не помещается — поле поиска
/// уходит второй строкой ([searchRowHeight] 56, шапка 125) и сведения в первой строке снова показываются, сколько
/// помещается. Строка шапки не переполняется.
/// `compact` 56 (тень `elevation.1`), `modal` 56 и `auth` 64 — без изменений. `Semantics(container)`.
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
    this.bell,
    this.user,
    this.onClose,
    this.closeLabel,
  });

  /// Вариант.
  final TopAppBarVariant variant;

  /// Класс окна для высоты и полей (по умолчанию — из `MediaQuery`).
  final WindowClass? windowClass;

  /// Заголовок (compact без поиска / modal).
  final String? title;

  /// Логотип (знак + wordmark — у вызывающего; на medium — только знак).
  final Widget? logo;

  /// «Бургер» слева от логотипа (`full`): открывает drawer навигации оболочки; `null` — кнопки нет.
  final VoidCallback? onMenu;

  /// Подпись и тултип «бургера» (`shell_menu_open` «Меню разделов»).
  final String? menuLabel;

  /// «Назад» или иной элемент слева (compact).
  final Widget? leading;

  /// Поле поиска (`SearchBar.header` / `.compact`).
  final Widget? search;

  /// Элементы правой группы до колокольчика (`full`: `SyncIndicator`, `TopAppBarCartButton`, `TopAppBarClock`).
  final List<Widget> actions;

  /// Колокольчик (`NotificationBell`) — между [actions] и [user].
  final Widget? bell;

  /// Блок пользователя ([TopAppBarUser]) — крайний справа.
  final Widget? user;

  /// Крестик (modal).
  final VoidCallback? onClose;

  /// Подпись крестика.
  final String? closeLabel;

  /// Наибольшая ширина поля поиска в `full` (прототип: `max-width: 680px`).
  static const double searchMaxWidth = 680;

  /// Наименьшая ширина поля поиска в строке шапки `full` ([TopAppBarFit]): плейсхолдер сокращается многоточием,
  /// для запроса остаётся ~90 lp рядом с иконкой, «очистить» и сканером.
  static const double searchMinWidth = 240;

  /// Наименьшая ширина поля поиска в строке шапки `full`, пока у аватара видны имя или роль ([TopAppBarUserFit.full]
  /// и [TopAppBarUserFit.short]): поле — главный элемент шапки, имя не сжимает его до [searchMinWidth] (плейсхолдер
  /// «Поиск товара по названию, ко…» читается). Не помещается — имя сворачивается раньше поля (QA паритета функций,
  /// ADR-112; 02 §3.1 п. 7).
  static const double searchComfortWidth = 320;

  /// Высота второй строки шапки с полем поиска ([TopAppBarFit.searchBelow]).
  static const double searchRowHeight = 56;

  /// Высота `full` на medium и шире: 12 + 44 + 12 и нижняя граница 1 (прототип `header`, ADR-114 п. 6). Токен
  /// раскладки [DsBreakpoints.topBarHeight] (68, кратен 4 — 03 §7.1) остаётся у шапки drawer навигации.
  static const double fullHeight = 69;

  /// Зазор правой группы `full` (прототип: `gap: 14px`); на узкой ступени ([TopAppBarFit.tight]) — 8.
  static const double rightGroupGap = 14;

  /// Невидимое поле цели касания 48 вокруг видимого квадрата 44 колокольчика ([TopAppBarIconButton]) — вычитается из
  /// зазоров рядом с ним.
  static const double _bellInset = (48 - TopAppBarIconButton.size) / 2;

  /// Высота по варианту и классу окна.
  static double heightFor(TopAppBarVariant v, WindowClass wc) => switch (v) {
    TopAppBarVariant.compact || TopAppBarVariant.modal => 56,
    TopAppBarVariant.auth => 64,
    TopAppBarVariant.full => wc == WindowClass.compact ? 56 : fullHeight,
  };

  @override
  Size get preferredSize => Size.fromHeight(heightFor(variant, windowClass ?? WindowClass.expanded));

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final WindowClass wc = windowClass ?? context.windowClass;
    final double height = heightFor(variant, wc);
    final double hPad = switch (wc) {
      WindowClass.compact => context.space.s4,
      WindowClass.medium => variant == TopAppBarVariant.full ? context.space.s4 : context.space.s6,
      WindowClass.expanded || WindowClass.large => context.space.s6,
    };
    if (variant == TopAppBarVariant.full) {
      final List<TopAppBarFit> ladder = search == null ? TopAppBarFit.ladderNoSearch : TopAppBarFit.ladder;
      return Semantics(
        container: true,
        explicitChildNodes: true,
        child: _TopAppBarFitLayout(
          steps: ladder.length,
          builder: (BuildContext context, _FitInfo info) {
            final TopAppBarFit fit = ladder[info.step];
            final Widget? searchSlot = search == null ? null : KeyedSubtree(key: info.probe.searchKey, child: search!);
            final double inner = info.constraints.maxWidth - 2 * hPad;
            // Ограничения ниже — не жёсткие (кроме места поля поиска): изменение размера элемента правой группы
            // (итог корзины, текст `SyncIndicator`, часы) доходит до `_RenderTopAppBarFit`, и ступень выбирается заново.
            return _TopAppBarFitScope(
              fit: fit,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.surface,
                  // `full` — без тени (прототип: только нижняя граница).
                  border: Border(bottom: BorderSide(color: c.border)),
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 1),
                  // Состав постоянный (строка — первым ребёнком колонки): при смене ступени элементы правой группы
                  // сохраняют состояние (фокус, слушатели клавиш), поле поиска переносится по ключу.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        height: height - 1,
                        child: Row(children: _full(context, fit, info.probe, searchSlot)),
                      ),
                      if (fit.searchBelow && searchSlot != null)
                        SizedBox(
                          key: const ValueKey<String>('top-app-bar-search-row'),
                          width: inner < searchMaxWidth ? inner : searchMaxWidth,
                          height: searchRowHeight,
                          child: Align(alignment: AlignmentDirectional.topStart, child: searchSlot),
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
    final List<Widget> children = switch (variant) {
      TopAppBarVariant.full => const <Widget>[],
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
        for (final Widget a in <Widget>[...actions, ?bell, ?user]) ...<Widget>[const SizedBox(width: 4), a],
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
          // `full` — без тени (прототип: только нижняя граница); `compact` — `elevation.1`, как раньше.
          boxShadow: variant == TopAppBarVariant.compact ? context.elevation.e1 : null,
        ),
        child: Row(children: children),
      ),
    );
  }

  /// Строка `full` по прототипу 2026-10-29 на ступени [fit]: поле поиска [searchSlot] в строке (не уже
  /// [searchMinWidth], при видимых имени или роли — [searchComfortWidth]; иначе ступень не подходит) или, при
  /// [TopAppBarFit.searchBelow], пустое место не уже зазора.
  /// Блок пользователя может показать подпись (имя или роль) — тогда на ступенях с подписью полю поиска нужна
  /// [searchComfortWidth]. Аватар без подписи ([TopAppBarUser.showText] `false`, пустые имя и роль) поле не сжимает;
  /// блок в обёртке (`Builder` у шапки каталога) считается с подписью.
  bool get _userText {
    final Widget? u = user;
    if (u == null) {
      return false;
    }
    return u is! TopAppBarUser || (u.showText && (u.name.trim().isNotEmpty || u.role.trim().isNotEmpty));
  }

  List<Widget> _full(BuildContext context, TopAppBarFit fit, _FitProbe probe, Widget? searchSlot) {
    final List<Widget> right = <Widget>[...actions, ?bell, ?user];
    final double gap = fit.tight ? context.space.s3 : context.space.s6;
    final double rightGap = fit.tight ? context.space.s2 : rightGroupGap;
    final bool inline = searchSlot != null && !fit.searchBelow;
    return <Widget>[
      if (onMenu != null) ...<Widget>[
        TopAppBarIconButton(
          key: const ValueKey<String>('top-app-bar-menu'),
          icon: Icons.menu_rounded,
          semanticLabel: menuLabel ?? '',
          onPressed: onMenu,
        ),
        SizedBox(width: context.space.s2),
      ],
      if (fit.logo) ?logo,
      if (inline) ...<Widget>[
        SizedBox(width: gap),
        // Поле — от логотипа (не по центру), растёт до 680; остаток строки — пустое место перед правой группой.
        Expanded(
          child: _FitProbeBox(
            probe: probe,
            minWidth: fit.user == TopAppBarUserFit.none || !_userText ? searchMinWidth : searchComfortWidth,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: searchMaxWidth),
                child: searchSlot,
              ),
            ),
          ),
        ),
        if (right.isNotEmpty) SizedBox(width: gap),
      ] else
        Expanded(
          child: _FitProbeBox(probe: probe, minWidth: right.isEmpty ? 0 : gap, child: const SizedBox.shrink()),
        ),
      for (int i = 0; i < right.length; i++) ...<Widget>[
        // Колокольчик занимает цель 48 при видимом квадрате 44: зазоры у него — на 2 меньше, чтобы видимые промежутки
        // были 14, как в прототипе.
        if (i > 0)
          SizedBox(width: rightGap - (identical(right[i], bell) || identical(right[i - 1], bell) ? _bellInset : 0)),
        KeyedSubtree(key: ValueKey<int>(i), child: right[i]),
      ],
    ];
  }
}

// ---------------------------------------------------------------- сжатие шапки по ширине

/// Сведения о раскладке для построителя шапки: ограничения, номер ступени и общий зонд.
typedef _FitInfo = ({BoxConstraints constraints, int step, _FitProbe probe});

/// Зонд ступени: текущий [_RenderFitProbe] (место поля поиска или пустое место строки) и ключ поля поиска — поле
/// переносится между строкой и второй строкой с сохранением состояния (фокус, текст, наведение).
final class _FitProbe {
  _RenderFitProbe? box;
  final GlobalKey searchKey = GlobalKey(debugLabel: 'top-app-bar-search');

  /// Ступень подходит: место зонда не уже его минимума (строка не переполнена). Значение зонд записывает при своей
  /// раскладке; не переложенный зонд сохраняет его — те же ограничения и минимум дают тот же ответ.
  bool get fits => box?.fits ?? true;
}

/// Построитель шапки во время раскладки (как `LayoutBuilder`): перебирает ступени [TopAppBarFit.ladder] с первой и
/// останавливается на первой, где зонд помещается. Перестраиваются только элементы, читающие [TopAppBarFit.of]; всё
/// — в одном кадре, без мигания и без переполнения строки на промежуточных ступенях (переполнение `RenderFlex`
/// сообщается только при отрисовке).
class _TopAppBarFitLayout extends AbstractLayoutBuilder<_FitInfo> {
  const _TopAppBarFitLayout({required this.steps, required this.builder});

  /// Число ступеней.
  final int steps;

  @override
  final Widget Function(BuildContext context, _FitInfo info) builder;

  @override
  _RenderTopAppBarFit createRenderObject(BuildContext context) => _RenderTopAppBarFit(steps);

  @override
  void updateRenderObject(BuildContext context, _RenderTopAppBarFit renderObject) => renderObject.steps = steps;
}

class _RenderTopAppBarFit extends RenderBox
    with
        RenderObjectWithChildMixin<RenderBox>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<_FitInfo, RenderBox> {
  _RenderTopAppBarFit(this._steps);

  int _steps;
  set steps(int value) {
    if (value == _steps) {
      return;
    }
    _steps = value;
    scheduleLayoutCallback();
  }

  int _step = 0;
  final _FitProbe _probe = _FitProbe();

  @override
  _FitInfo get layoutInfo => (constraints: constraints, step: _step, probe: _probe);

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    // Нежёсткие ограничения ребёнку: под шапкой нет границы перекладки, рост элемента правой группы перекладывает и
    // этот объект (новый выбор ступени).
    final BoxConstraints loose = constraints.loosen();
    // С первой ступени: выбирается наименее свёрнутая из подходящих (содержимое могло и сузиться — итог корзины,
    // текст `SyncIndicator`). Каждая проба перестраивает только зависимых от ступени и раскладывает строку шапки.
    for (int s = 0; s < _steps; s++) {
      _step = s;
      runLayoutCallback();
      final RenderBox? child = this.child;
      if (child == null) {
        break;
      }
      child.layout(loose, parentUsesSize: true);
      if (_probe.fits) {
        break;
      }
    }
    final RenderBox? child = this.child;
    size = child == null ? constraints.smallest : constraints.constrain(child.size);
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      child?.getDistanceToActualBaseline(baseline) ?? super.computeDistanceToActualBaseline(baseline);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child != null) {
      context.paintChild(child, offset);
    }
  }
}

/// Зонд места в строке шапки: сообщает [_FitProbe] свою ширину и минимум.
class _FitProbeBox extends SingleChildRenderObjectWidget {
  const _FitProbeBox({required this.probe, required this.minWidth, super.child});

  final _FitProbe probe;
  final double minWidth;

  @override
  _RenderFitProbe createRenderObject(BuildContext context) => _RenderFitProbe(probe, minWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderFitProbe renderObject) {
    renderObject
      ..probe = probe
      ..minWidth = minWidth;
  }
}

class _RenderFitProbe extends RenderProxyBox {
  _RenderFitProbe(this._probe, this._minWidth);

  /// Место не уже [minWidth] — по последней раскладке.
  bool fits = true;

  _FitProbe _probe;
  set probe(_FitProbe value) {
    if (identical(value, _probe)) {
      return;
    }
    if (identical(_probe.box, this)) {
      _probe.box = null;
    }
    _probe = value;
    if (attached) {
      _probe.box = this;
    }
  }

  /// Минимум места.
  double _minWidth;
  set minWidth(double value) {
    if (value == _minWidth) {
      return;
    }
    _minWidth = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    fits = size.width + 0.01 >= _minWidth;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _probe.box = this;
  }

  @override
  void detach() {
    if (identical(_probe.box, this)) {
      _probe.box = null;
    }
    super.detach();
  }
}

/// Кнопка-иконка шапки `full` (прототип: «бургер», колокольчик): квадрат 44 с радиусом `control` 10 (ADR-114),
/// прозрачная; иконка 22 `textPrimary` (выбранная — `primaryText`) — [glyph] прототипа (колокол — линия 1,8) или
/// Material [icon]; hover — `surfaceHover` (`.ghost:hover` прототипа), pressed — `iconButtonPressed`, фокус — кольцо
/// `focus` (синее); цель касания 48 (03 §7.4). [badge] — в правом верхнем углу квадрата (`top 6 / right 6`).
/// Тултип — [tooltip] или [semanticLabel].
class TopAppBarIconButton extends StatelessWidget {
  /// Создаёт кнопку.
  const TopAppBarIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.glyph,
    this.badge,
    this.selected = false,
    this.tooltip,
  });

  /// Иконка (Material); при [glyph] не рисуется.
  final IconData icon;

  /// Контурный глиф прототипа вместо [icon] (колокол уведомлений).
  final DsGlyphKind? glyph;

  /// Подпись для screen reader (из ARB).
  final String semanticLabel;

  /// Действие; `null` — недоступна.
  final VoidCallback? onPressed;

  /// Бейдж (позиция — `top 6 / right 6` внутри квадрата).
  final Widget? badge;

  /// Выбрана (открыт экран кнопки): иконка `primaryText`.
  final bool selected;

  /// Тултип; по умолчанию — [semanticLabel]. Пустая строка отключает тултип.
  final String? tooltip;

  /// Сторона квадрата.
  static const double size = 44;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.control);
    final bool enabled = onPressed != null;
    final DsGlyphKind? glyph = this.glyph;
    final Widget button = Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: onPressed,
      child: DsInteractive(
        enabled: enabled,
        onTap: onPressed,
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceHover : Colors.transparent);
          final Color fg = !s.enabled ? c.disabledText : (selected ? c.primaryText : c.textPrimary);
          return DsTapTarget(
            child: DsFocusRing(
              visible: s.focused,
              borderRadius: radius,
              child: AnimatedContainer(
                duration: context.motion.of(context.motion.fast),
                width: size,
                height: size,
                decoration: BoxDecoration(color: bg, borderRadius: radius),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: <Widget>[
                    if (glyph == null) Icon(icon, size: 22, color: fg) else DsGlyph(kind: glyph, size: 22, color: fg),
                    if (badge != null) Positioned(top: 6, right: 6, child: badge!),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    return AppTooltip(message: tooltip ?? semanticLabel, child: button);
  }
}

/// Часы шапки (02 UI-10-005, UI-10-032, UI-30-013; паритет функций ADR-112): компактный вторичный текст правой
/// группы перед колокольчиком — «09:41» `body 600 textPrimary tnum` и под ним дата «пн, 22 окт» `caption
/// textSecondary`, выравнивание по правому краю. Дата сворачивается по ширине шапки ([TopAppBarFit.date]): сначала
/// до [shortDate] (если задана — на «Кассе» «Чт, 22 октября 2026» → «чт, 22 окт»), затем — только время. Свёрнутая
/// дата — в тултипе и `Semantics` полностью. [timeOnly] — всегда только время. Не интерактивны; доступное имя —
/// «09:41, пн, 22 окт». Строки форматирует вызывающий код (`DsBishkekTime`, Asia/Bishkek, по границе минуты).
class TopAppBarClock extends StatelessWidget {
  /// Создаёт часы.
  const TopAppBarClock({super.key, required this.time, required this.date, this.shortDate, this.timeOnly = false});

  /// Время.
  final String time;

  /// Дата.
  final String date;

  /// Короткая дата для ступени [TopAppBarDateFit.short]; `null` — [date] и так короткая.
  final String? shortDate;

  /// Только время; дата — в тултипе и `Semantics`.
  final bool timeOnly;

  @override
  Widget build(BuildContext context) {
    final TopAppBarDateFit dateFit = timeOnly ? TopAppBarDateFit.none : TopAppBarFit.of(context).date;
    final String? shown = switch (dateFit) {
      TopAppBarDateFit.full => date,
      TopAppBarDateFit.short => shortDate ?? date,
      TopAppBarDateFit.none => null,
    };
    final DsColors c = context.colors;
    final Widget timeText = Text(
      time,
      maxLines: 1,
      style: context.text.body.copyWith(
        fontWeight: FontWeight.w600,
        color: c.textPrimary,
        fontFeatures: DsTypography.numeric,
        height: 1.2,
      ),
    );
    final Widget body = shown == null
        ? timeText
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              timeText,
              Text(
                shown,
                key: const ValueKey<String>('top-app-bar-clock-date'),
                maxLines: 1,
                style: context.text.caption.copyWith(color: c.textSecondary, height: 1.2),
              ),
            ],
          );
    final Widget clock = Semantics(label: '$time, $date', excludeSemantics: true, child: body);
    return shown == date ? clock : AppTooltip(message: date, child: clock);
  }
}

/// Блок пользователя шапки (прототип, ADR-114 п. 6): аватар 38 — круг `primaryContainer` с инициалом `primaryText`
/// `avatarInitial` 15/700; через 10 — имя 14/600 `textPrimary` и роль 12/400 `catalogMeta` (строка 1,2) — при
/// [showText], не шире [textMaxWidth] с многоточием: длинное ФИО не сжимает поиск. Без своих полей: текст кончается у
/// края шапки, как в прототипе; цель касания — не ниже 48. В шапке `full` подпись сворачивается по ширине
/// ([TopAppBarFit.user], паритет функций ADR-112): сначала остаётся только имя не шире [nameShortMaxWidth] (роль — в
/// меню и `Semantics`), затем — только аватар. Тап → меню аватара (Профиль · Настройки · Синхронизация · Заблокировать
/// · Выйти — у вызывающего; первым — заголовок с именем и ролью). Читается [semanticLabel] («Профиль: Абдулла,
/// Продавец» — `profile_avatar_a11y`, 02 A8), без него — «Абдулла, Продавец»; цель касания ≥ 48.
class TopAppBarUser extends StatelessWidget {
  /// Создаёт блок.
  const TopAppBarUser({
    super.key,
    required this.name,
    required this.role,
    this.onTap,
    this.showText = true,
    this.showRole = true,
    this.maxTextWidth = textMaxWidth,
    this.semanticLabel,
    this.initials,
  });

  /// Имя (из `/me`).
  final String name;

  /// Роль (`RoleBadge.text`).
  final String role;

  /// Открыть меню.
  final VoidCallback? onTap;

  /// Показывать имя (и роль — при [showRole]); `false` — только аватар.
  final bool showText;

  /// Показывать роль под именем (при [showText]).
  final bool showRole;

  /// Наибольшая ширина имени и роли.
  final double maxTextWidth;

  /// Подпись для screen reader (из ARB); `null` — «имя, роль».
  final String? semanticLabel;

  /// Буквы в круге аватара; `null` — первая буква [name] (шапка medium+). Шапка телефона передаёт инициалы
  /// ([initialsOf]: первые буквы двух первых слов ФИО; ADR-122).
  final String? initials;

  /// Инициалы ФИО: первые буквы двух первых слов (`Айбек Асанов` → `АА`); пусто — `?`.
  static String initialsOf(String name) {
    final String letters = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((String p) => p.isNotEmpty)
        .take(2)
        .map((String p) => p.characters.first.toUpperCase())
        .join();
    return letters.isEmpty ? '?' : letters;
  }

  /// Диаметр аватара.
  static const double avatarSize = 38;

  /// Зазор между аватаром и подписью (прототип: `gap: 10px`).
  static const double textGap = 10;

  /// Наибольшая ширина имени и роли.
  static const double textMaxWidth = 160;

  /// Наибольшая ширина сокращённого имени (ступень [TopAppBarUserFit.short]).
  static const double nameShortMaxWidth = 96;

  @override
  Widget build(BuildContext context) {
    final TopAppBarUserFit userFit = TopAppBarFit.of(context).user;
    final bool showText = this.showText && userFit != TopAppBarUserFit.none;
    final bool showRole = this.showRole && userFit == TopAppBarUserFit.full;
    final double maxTextWidth = userFit == TopAppBarUserFit.full
        ? this.maxTextWidth
        : (this.maxTextWidth < nameShortMaxWidth ? this.maxTextWidth : nameShortMaxWidth);
    final DsColors c = context.colors;
    final String initials = this.initials ?? (name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase());
    final BorderRadius radius = BorderRadius.all(context.radii.control);
    return Semantics(
      button: onTap != null,
      label: semanticLabel ?? (role.isEmpty ? name : '$name, $role'),
      excludeSemantics: true,
      onTap: onTap,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            decoration: BoxDecoration(color: s.hovered ? c.surfaceHover : Colors.transparent, borderRadius: radius),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: avatarSize,
                  height: avatarSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.primaryContainer,
                    borderRadius: BorderRadius.all(context.radii.avatar),
                  ),
                  child: Text(
                    initials,
                    textScaler: TextScaler.noScaling,
                    style: context.text.avatarInitial.copyWith(color: c.primaryText),
                  ),
                ),
                if (showText) ...<Widget>[
                  const SizedBox(width: textGap),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxTextWidth),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                            height: 1.2,
                          ),
                        ),
                        if (showRole && role.isNotEmpty)
                          Text(
                            role,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // 12 #6B7487 на `surface` — 4,69:1 (CP-093, DS-007 ред. 1.18); на фоне наведения
                            // `catalogMeta` запрещён (CP-124, 4,45:1) — `textSecondary` (CP-013).
                            style: context.text.caption.copyWith(
                              color: s.hovered ? c.textSecondary : c.catalogMeta,
                              height: 1.2,
                            ),
                          ),
                      ],
                    ),
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
