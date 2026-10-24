import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `SearchBar` (03 §9.7).
enum SearchBarVariant {
  /// В `TopAppBarPos` (flex, ≤ 720).
  header,

  /// На всю ширину под шапкой (compact).
  compact,

  /// Поиск клиентов: свой плейсхолдер, без сканера.
  customers,
}

/// Поле поиска `SearchBar` (03 §9.7). Имя совпадает с Material `SearchBar` — импортируйте
/// `package:flutter/material.dart` с `hide SearchBar` (канон имён — ядро §8.5).
///
/// Фон `surfaceVariant`, высота 44 (compact) / 48; иконка `search` 20; плейсхолдер `textSecondary`
/// (на `surfaceVariant` `textTertiary` < 4.5 — 03 §9.7); фокус — обводка 2 px `primaryText`
/// и фон `surface`; загрузка — `AppProgress.linear` 2 px под полем. Debounce, история и
/// подсказки — у фичи каталога (компонент только сообщает ввод).
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
    final double height = context.windowClass == WindowClass.compact ? 44 : 48;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    final String placeholder =
        widget.placeholder ??
        (widget.variant == SearchBarVariant.customers
            ? l10n.ds_search_placeholder_customers
            : l10n.ds_search_placeholder_products);
    final bool scanner = widget.onScan != null && widget.variant != SearchBarVariant.customers;

    final Widget box = AnimatedContainer(
      duration: context.motion.of(context.motion.fast),
      height: height,
      decoration: BoxDecoration(color: focused ? c.surface : c.surfaceVariant, borderRadius: radius),
      // Обводка рисуется поверх (foreground), чтобы не уменьшать высоту поля и тач-целей (48).
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: focused
            ? Border.all(color: c.primaryText, width: 2)
            : Border.all(color: hovered ? c.border : Colors.transparent),
      ),
      padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
      child: Row(
        children: <Widget>[
          ExcludeSemantics(child: Icon(Icons.search_rounded, size: 20, color: c.textSecondary)),
          const SizedBox(width: 8),
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
                style: context.text.bodyLg.copyWith(color: c.textPrimary),
                cursorColor: c.primaryText,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                maxLines: 1,
                decoration: InputDecoration(
                  isDense: true,
                  // Поле занимает всю высоту контейнера: тач-цель = высота SearchBar (44/48).
                  contentPadding: EdgeInsets.symmetric(vertical: (height - 24) / 2),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  filled: false,
                  hintText: placeholder,
                  hintMaxLines: 1,
                  hintStyle: context.text.bodyLg.copyWith(color: c.textSecondary, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ),
          if (_controller.text.isNotEmpty)
            AppIconButton(
              icon: Icons.close_rounded,
              iconSize: 20,
              semanticLabel: l10n.ds_button_reset,
              tooltip: '',
              onPressed: _clear,
            ),
          if (scanner)
            AppIconButton(
              icon: Icons.barcode_reader,
              semanticLabel: widget.scannerLabel ?? '',
              onPressed: widget.onScan,
            ),
        ],
      ),
    );

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
    if (widget.variant == SearchBarVariant.header) {
      return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: field);
    }
    return field;
  }
}
