import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `SearchBar` (03 §9.7).
enum SearchBarVariant {
  /// В `TopAppBarPos.full` (прототип 2026-10-29): высота 44, до 680, кнопки 32 внутри поля.
  header,

  /// На всю ширину под шапкой (compact).
  compact,

  /// Поиск клиентов: свой плейсхолдер, без сканера.
  customers,
}

/// Поле поиска `SearchBar` (03 §9.7). Имя совпадает с Material `SearchBar` — импортируйте
/// `package:flutter/material.dart` с `hide SearchBar` (канон имён — ядро §8.5).
///
/// * [SearchBarVariant.header] (шапка medium+, ADR-112): высота 44 (область ввода и тач-цель поля — 48), радиус
///   `md`, фон `surfaceVariant`, поля 16 слева / 8 справа, иконка `search` 18 `textSecondary`, текст `body`,
///   плейсхолдер `textTertiary` (4.51:1 на `surfaceVariant`, ADR-111); «очистить» и сканер — кнопки 32×32 с
///   радиусом `sm` внутри поля, цель касания 44;
/// * [SearchBarVariant.compact] / [SearchBarVariant.customers]: высота 44 (compact) / 48, иконка 20, текст
///   `bodyLg`, плейсхолдер `textSecondary`, кнопки `AppIconButton`.
///
/// Фокус — обводка 2 px `primaryText` и фон `surface`; загрузка — `AppProgress.linear` 2 px под полем.
/// Debounce, история и подсказки — у фичи каталога (компонент только сообщает ввод).
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
    final BorderRadius radius = BorderRadius.all(header ? context.radii.md : context.radii.sm);
    final TextStyle textStyle = header ? context.text.body : context.text.bodyLg;
    final double line = (textStyle.fontSize ?? 14) * (textStyle.height ?? 1.4);
    final String placeholder =
        widget.placeholder ??
        (widget.variant == SearchBarVariant.customers
            ? l10n.ds_search_placeholder_customers
            : l10n.ds_search_placeholder_products);
    final bool scanner = widget.onScan != null && widget.variant != SearchBarVariant.customers;

    // header: поле 44 визуально, область ввода и тач-цель — 48 (по 2 px сверху и снизу за кромкой фона).
    final double target = header ? SearchBar.headerTarget : height;
    final Widget content = Padding(
      padding: header
          ? EdgeInsetsDirectional.only(start: context.space.s4, end: context.space.s2)
          : const EdgeInsetsDirectional.only(start: 12, end: 4),
      child: Row(
        children: <Widget>[
          ExcludeSemantics(
            child: Icon(Icons.search_rounded, size: header ? 18 : 20, color: c.textSecondary),
          ),
          SizedBox(width: header ? context.space.s3 : 8),
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
                style: textStyle.copyWith(color: c.textPrimary),
                cursorColor: c.primaryText,
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
                  // header: `textTertiary` на `surfaceVariant` — 4.51:1 (ADR-111, CP-084); иначе — `textSecondary`.
                  hintStyle: textStyle.copyWith(
                    color: header ? c.textTertiary : c.textSecondary,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            header
                ? _FieldIconButton(
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
      decoration: BoxDecoration(color: focused ? c.surface : c.surfaceVariant, borderRadius: radius),
      // Обводка рисуется поверх (foreground), чтобы не уменьшать высоту поля и тач-целей.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: focused
            ? Border.all(color: c.primaryText, width: 2)
            : Border.all(color: hovered ? c.border : Colors.transparent),
      ),
      child: header ? null : content,
    );
    final Widget box = header
        ? SizedBox(
            height: target,
            child: Stack(
              children: <Widget>[
                Positioned(left: 0, right: 0, top: (target - height) / 2, height: height, child: background),
                Positioned.fill(child: content),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            box,
            // Загрузка: тонкая полоса 2 px под полем, спиннер в суффиксе не дублируется (03 §9.7).
            SizedBox(height: 2, child: widget.loading ? const AppProgress.linear(thin: true) : null),
          ],
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
