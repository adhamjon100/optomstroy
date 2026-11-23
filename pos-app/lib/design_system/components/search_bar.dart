import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `SearchBar` (03 §9.7).
enum SearchBarVariant {
  /// В `TopAppBarPos.full` (прототип, ADR-114): высота 44, радиус 10, до 680, кнопки 32 внутри поля.
  header,

  /// На всю ширину под шапкой (compact).
  compact,

  /// Поиск клиентов: свой плейсхолдер, без сканера.
  customers,
}

/// Поле поиска `SearchBar` (03 §9.7). Имя совпадает с Material `SearchBar` — импортируйте
/// `package:flutter/material.dart` с `hide SearchBar` (канон имён — ядро §8.5).
///
/// * [SearchBarVariant.header] (шапка medium+, прототип без округления — ADR-114 п. 6): высота 44 (область ввода и
///   тач-цель поля — 48), радиус `control` 10, фон `surfaceVariant` #EAF1FB, поля 14 слева / 8 справа, зазор 10;
///   лупа — глиф прототипа 18 `textSecondary` (линия 2), текст `body` 14 `textPrimary`, плейсхолдер
///   `searchPlaceholder` #757575 (цвет Chrome по умолчанию; 4,05:1 — исключение ADR-114 п. 9 (1), CP-097);
///   «очистить» (крест; в прототипе её нет — паритет функций) и сканер (штрихкод в рамке, линия 1,8) — кнопки 32×32
///   с радиусом `sm` внутри поля, цель касания 48;
/// * [SearchBarVariant.compact] / [SearchBarVariant.customers]: высота 44 (compact) / 48, иконка 20, текст
///   `bodyLg`, плейсхолдер `textSecondary`, кнопки `AppIconButton`.
///
/// Фокус — обводка 2 px и каретка `textPrimary` (нейтральное состояние ввода, как у `AppTextField`; не фирменная
/// `primaryText`, которую не отличить от `error`; пакет wave2:APP-POLISH) и фон `surface`; загрузка —
/// `AppProgress.linear` 2 px под полем.
/// Debounce, история и подсказки — у фичи каталога (компонент только сообщает ввод).
///
/// В области «общее устройство» `PrivateInputScope` (03 §9.7, §9.74, редакция 1.19; DS-099): системная клавиатура
/// остаётся, но без подсказок, автоисправления, обучения клавиатуры и автозаполнения; выделения, контекстного меню и
/// вставки нет. Вне области — как прежде.
class SearchBar extends StatefulWidget {
  /// Создаёт поле поиска.
  const SearchBar({
    super.key,
    this.variant = SearchBarVariant.header,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.semanticLabel,
    this.scannerLabel,
    this.onScan,
    this.loading = false,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  /// Вариант.
  final SearchBarVariant variant;

  /// Контроллер.
  final TextEditingController? controller;

  /// Узел фокуса (F2 / Ctrl+F на Windows ставит фокус сюда — обработка у каркаса).
  final FocusNode? focusNode;

  /// Плейсхолдер (по умолчанию — `ds_search_placeholder_products` / `_customers`).
  final String? placeholder;

  /// Подпись для screen reader («Поиск»).
  final String? semanticLabel;

  /// Подпись кнопки сканера.
  final String? scannerLabel;

  /// Кнопка сканера `barcode_scanner`; `null` — кнопки нет.
  final VoidCallback? onScan;

  /// Поиск выполняется (после debounce).
  final bool loading;

  /// Ввод.
  final ValueChanged<String>? onChanged;

  /// Enter — немедленный поиск.
  final ValueChanged<String>? onSubmitted;

  /// Автофокус.
  final bool autofocus;

  /// Высота варианта `header` (визуально).
  static const double headerHeight = 44;

  /// Высота области ввода варианта `header` — тач-цель поля 48 (03 §7.4).
  static const double headerTarget = 48;

  /// Наибольшая ширина варианта `header` (прототип: `max-width: 680px`).
  static const double headerMaxWidth = 680;

  /// Поле `header` слева (прототип: `padding-left: 14px`).
  static const double _headerPadStart = 14;

  /// Зазор `header` между лупой и вводом (прототип: `gap: 10px`).
  static const double _headerGap = 10;

  @override
  State<SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<SearchBar> {
  TextEditingController? _ownController;
  FocusNode? _ownFocus;
  bool _focused = false;
  bool _hovered = false;

  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _controller.addListener(_onText);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _controller.removeListener(_onText);
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() => _focused = _focus.hasFocus);

  void _onText() => setState(() {});

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsInteractionState? preview = DsStatePreview.maybeOf(context);
    final bool focused = preview?.focused ?? _focused;
    final bool hovered = preview?.hovered ?? _hovered;
    final bool header = widget.variant == SearchBarVariant.header;
    final double height = header ? SearchBar.headerHeight : (context.windowClass == WindowClass.compact ? 44 : 48);
    final BorderRadius radius = BorderRadius.all(header ? context.radii.control : context.radii.sm);
    final TextStyle textStyle = header ? context.text.body : context.text.bodyLg;
    final double line = (textStyle.fontSize ?? 14) * (textStyle.height ?? 1.4);
    final String placeholder =
        widget.placeholder ??
        (widget.variant == SearchBarVariant.customers
            ? l10n.ds_search_placeholder_customers
            : l10n.ds_search_placeholder_products);
    final bool scanner = widget.onScan != null && widget.variant != SearchBarVariant.customers;
    // Область «общее устройство» (03 §9.74, DS-099): вне неё значения TextField — прежние (по умолчанию).
    final bool private = PrivateInputScope.of(context);

    // header: поле 44 визуально, область ввода и тач-цель — 48 (по 2 px сверху и снизу за кромкой фона).
    final double target = header ? SearchBar.headerTarget : height;
    final Widget content = Padding(
      // header: `padding: 0 8px 0 14px; gap: 10px` прототипа. Правое поле 8 — это часть цели касания 48 кнопки
      // 32 (по 8 с каждой стороны), поэтому при кнопке справа поля нет: видимая кнопка — в 8 от края, как в прототипе.
      padding: header
          ? EdgeInsetsDirectional.only(
              start: SearchBar._headerPadStart,
              end: scanner || _controller.text.isNotEmpty ? 0 : context.space.s2,
            )
          : const EdgeInsetsDirectional.only(start: 12, end: 4),
      child: Row(
        children: <Widget>[
          if (header)
            DsGlyph(kind: DsGlyphKind.magnifier, size: 18, color: c.textSecondary)
          else
            ExcludeSemantics(child: Icon(Icons.search_rounded, size: 20, color: c.textSecondary)),
          SizedBox(width: header ? SearchBar._headerGap : 8),
          Expanded(
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                // Esc — очистка (03 §9.7).
                const SingleActivator(LogicalKeyboardKey.escape): _clear,
              },
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                textInputAction: TextInputAction.search,
                enableSuggestions: !private,
                autocorrect: private ? false : null,
                enableIMEPersonalizedLearning: !private,
                enableInteractiveSelection: private ? false : null,
                contextMenuBuilder: PrivateInputScope.contextMenuBuilderFor(private: private),
                autofillHints: private ? null : PrivateInputScope.defaultAutofillHints,
                style: textStyle.copyWith(color: c.textPrimary),
                cursorColor: c.textPrimary,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                maxLines: 1,
                decoration: InputDecoration(
                  isDense: true,
                  // Поле занимает всю высоту области: тач-цель = 48 (header) / высота SearchBar (44/48).
                  contentPadding: EdgeInsets.symmetric(vertical: (target - line) / 2),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  hintText: placeholder,
                  hintMaxLines: 1,
                  // header: `searchPlaceholder` #757575 прототипа на `surfaceVariant` — 4,05:1, исключение по решению
                  // владельца (ADR-114 п. 9 (1), CP-097; AA-оттенок #6D6D6D — `alternatives.AA_2026_10_31`); иначе —
                  // `textSecondary`.
                  hintStyle: textStyle.copyWith(
                    color: header ? c.searchPlaceholder : c.textSecondary,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            header
                ? _FieldIconButton(
                    // В прототипе кнопки нет (паритет функций: Esc и «очистить») — Material-крест, как раньше.
                    icon: Icons.close_rounded,
                    iconSize: 18,
                    color: c.textSecondary,
                    semanticLabel: l10n.ds_button_reset,
                    tooltip: '',
                    onPressed: _clear,
                  )
                : AppIconButton(
                    icon: Icons.close_rounded,
                    iconSize: 20,
                    semanticLabel: l10n.ds_button_reset,
                    tooltip: '',
                    onPressed: _clear,
                  ),
          if (scanner)
            header
                ? _FieldIconButton(
                    key: const ValueKey<String>('search-bar-scanner'),
                    icon: Icons.barcode_reader,
                    // Прототип: штрихкод в рамке контуром (в Material Icons такого глифа нет).
                    glyph: DsGlyphKind.barcodeScan,
                    iconSize: 20,
                    color: c.textPrimary,
                    semanticLabel: widget.scannerLabel ?? '',
                    onPressed: widget.onScan,
                  )
                : AppIconButton(
                    icon: Icons.barcode_reader,
                    semanticLabel: widget.scannerLabel ?? '',
                    onPressed: widget.onScan,
                  ),
        ],
      ),
    );
    final Widget background = AnimatedContainer(
      duration: context.motion.of(context.motion.fast),
      height: height,
      // Фокус: у поля шапки фон не меняется (прототип: `#EAF1FB`, `outline: none`; ревью V-02) — фокус видно по обводке
      // 2 `textPrimary` (A11Y-010; 14,7 : 1 к `surfaceVariant`); у остальных вариантов — фон `surface` (03 §9.7).
      decoration: BoxDecoration(color: focused && !header ? c.surface : c.surfaceVariant, borderRadius: radius),
      // Обводка рисуется поверх (foreground), чтобы не уменьшать высоту поля и тач-целей.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: focused
            ? Border.all(color: c.textPrimary, width: 2)
            : Border.all(color: hovered ? c.border : Colors.transparent),
      ),
      child: header ? null : content,
    );
    // Загрузка: тонкая полоса 2 px под полем, спиннер в суффиксе не дублируется (03 §9.7). У `header` полоса лежит в
    // нижнем невидимом поле области 48 (под фоном 44), поэтому поле стоит в шапке по центру, как в прототипе (12 сверху).
    final Widget progress = SizedBox(height: 2, child: widget.loading ? const AppProgress.linear(thin: true) : null);
    final double gap = (target - height) / 2;
    final Widget box = header
        ? SizedBox(
            height: target,
            child: Stack(
              children: <Widget>[
                Positioned(left: 0, right: 0, top: gap, height: height, child: background),
                Positioned.fill(child: content),
                Positioned(
                  left: 0,
                  right: 0,
                  top: gap + height,
                  height: 2,
                  child: IgnorePointer(child: progress),
                ),
              ],
            ),
          )
        : background;

    final Widget field = MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        label: widget.semanticLabel,
        child: header
            ? box
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[box, progress],
              ),
      ),
    );
    if (header) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: SearchBar.headerMaxWidth),
        child: field,
      );
    }
    return field;
  }
}

/// Кнопка внутри поля `header` (прототип: 32×32, радиус 8): hover — `surfaceHover`, pressed —
/// `iconButtonPressed`, фокус — кольцо `focus`; цель касания 48 × 48 = высота области ввода [SearchBar.headerTarget]
/// (03 §7.4; поле стоит в шапке всех экранов сотрудника, в том числе на сенсорных POS-мониторах).
class _FieldIconButton extends StatelessWidget {
  const _FieldIconButton({
    super.key,
    required this.icon,
    required this.iconSize,
    required this.color,
    required this.semanticLabel,
    required this.onPressed,
    this.tooltip,
    this.glyph,
  });

  final IconData icon;

  /// Контурный глиф вместо [icon] (сканер в шапке — штрихкод в рамке).
  final DsGlyphKind? glyph;
  final double iconSize;
  final Color color;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    final Widget button = Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: onPressed != null,
        onTap: onPressed,
        builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
          minWidth: SearchBar.headerTarget,
          minHeight: SearchBar.headerTarget,
          child: DsFocusRing(
            visible: s.focused,
            borderRadius: radius,
            child: AnimatedContainer(
              duration: context.motion.of(context.motion.fast),
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceHover : Colors.transparent),
                borderRadius: radius,
              ),
              child: glyph == null
                  ? Icon(icon, size: iconSize, color: s.enabled ? color : c.disabledText)
                  : DsGlyph(kind: glyph!, size: iconSize, color: s.enabled ? color : c.disabledText),
            ),
          ),
        ),
      ),
    );
    final String tip = tooltip ?? semanticLabel;
    return tip.isEmpty ? button : AppTooltip(message: tip, child: button);
  }
}
