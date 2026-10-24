import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Варианты `AppTextField` (03 §9.3).
enum AppTextFieldVariant { single, multiline, number, password, readOnly }

/// Размеры поля (03 §9.3): S 40 / M 48 / L 56; паддинг 12 / 16 / 16.
enum AppTextFieldSize {
  /// 40 lp.
  s(40, 12),

  /// 48 lp (стандарт на expanded).
  m(48, 16),

  /// 56 lp (compact, `PhoneField.auth`).
  l(56, 16);

  const AppTextFieldSize(this.height, this.horizontalPadding);

  /// Высота контейнера.
  final double height;

  /// Горизонтальный паддинг.
  final double horizontalPadding;
}

/// Поле ввода `AppTextField` (03 §9.3).
///
/// Подпись `label 13/500 textSecondary` над полем → контейнер `surface`, обводка 1 px
/// `borderStrong`, радиус `sm` → текст `bodyLg` → суффикс (очистка / спиннер / иконка ошибки /
/// счётчик) → подсказка или ошибка `caption`. Фокус — обводка 2 px `primaryText` без внешнего
/// кольца; ошибка — 2 px `error` + текст из ARB (передаёт вызывающий код).
class AppTextField extends StatefulWidget {
  /// Создаёт поле.
  const AppTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.label,
    this.hint,
    this.helper,
    this.errorText,
    this.variant = AppTextFieldVariant.single,
    this.size = AppTextFieldSize.m,
    this.prefixIcon,
    this.prefixText,
    this.prefixStyle,
    this.suffix,
    this.withClear = false,
    this.loading = false,
    this.enabled = true,
    this.maxLength,
    this.inputFormatters,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.autofocus = false,
    this.textStyle,
    this.semanticLabel,
    this.onChanged,
    this.onSubmitted,
    this.onFocusChange,
    this.expand = true,
  });

  /// Контроллер (если не задан — создаётся внутри).
  final TextEditingController? controller;

  /// Узел фокуса (если не задан — создаётся внутри).
  final FocusNode? focusNode;

  /// Подпись над полем.
  final String? label;

  /// Плейсхолдер (`textTertiary`, только на `surface`).
  final String? hint;

  /// Подсказка под полем (`caption textSecondary`).
  final String? helper;

  /// Текст ошибки (`caption error`); не `null` — состояние error.
  final String? errorText;

  /// Вариант.
  final AppTextFieldVariant variant;

  /// Размер.
  final AppTextFieldSize size;

  /// Префикс-иконка 20.
  final IconData? prefixIcon;

  /// Нередактируемый текстовый префикс («+996»).
  final String? prefixText;

  /// Стиль префикса (по умолчанию `bodyLg 500 textSecondary`).
  final TextStyle? prefixStyle;

  /// Свой суффикс (иконка/кнопка).
  final Widget? suffix;

  /// Кнопка очистки `close` в суффиксе при непустом значении.
  final bool withClear;

  /// Серверная проверка: суффикс → `AppProgress.circular 16`, ввод разрешён.
  final bool loading;

  /// Доступно ли поле.
  final bool enabled;

  /// Лимит длины (обязателен для полей, уходящих в 1С); у `multiline` — счётчик «0/200».
  final int? maxLength;

  /// Форматтеры ввода.
  final List<TextInputFormatter>? inputFormatters;

  /// Клавиатура (по умолчанию — по варианту).
  final TextInputType? keyboardType;

  /// Действие клавиатуры (`next`/`done`).
  final TextInputAction? textInputAction;

  /// Подсказки автозаполнения.
  final Iterable<String>? autofillHints;

  /// Автофокус.
  final bool autofocus;

  /// Стиль текста (по умолчанию `bodyLg 400 textPrimary`; `number` — с `tnum`).
  final TextStyle? textStyle;

  /// Подпись для screen reader (по умолчанию [label]).
  final String? semanticLabel;

  /// Изменение значения.
  final ValueChanged<String>? onChanged;

  /// Отправка (Enter).
  final ValueChanged<String>? onSubmitted;

  /// Изменение фокуса (персонаж `typing`, 03 §9.4).
  final ValueChanged<bool>? onFocusChange;

  /// На всю доступную ширину.
  final bool expand;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  TextEditingController? _ownController;
  FocusNode? _ownFocus;
  bool _focused = false;

  TextEditingController get _controller => widget.controller ?? (_ownController ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_onText);
      _controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _controller.removeListener(_onText);
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focused != _focus.hasFocus) {
      setState(() => _focused = _focus.hasFocus);
      widget.onFocusChange?.call(_focused);
    }
  }

  void _onText() => setState(() {});

  bool get _multiline => widget.variant == AppTextFieldVariant.multiline;
  bool get _readOnly => widget.variant == AppTextFieldVariant.readOnly;
  bool get _hasError => widget.errorText != null;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final DsTypography t = context.text;
    final DsInteractionState? preview = DsStatePreview.maybeOf(context);
    final bool focused = preview?.focused ?? _focused;
    final bool enabled = widget.enabled;

    final Color labelColor = !enabled
        ? c.textSecondary
        : _hasError
        ? c.error
        : focused
        ? c.primaryText
        : c.textSecondary;

    TextStyle textStyle = widget.textStyle ?? t.bodyLg;
    if (widget.variant == AppTextFieldVariant.number) {
      textStyle = textStyle.copyWith(fontFeatures: DsTypography.numeric);
    }
    textStyle = textStyle.copyWith(color: enabled ? c.textPrimary : c.disabledText);

    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color, width: width),
    );

    final double lineHeight = (textStyle.fontSize ?? 16) * (textStyle.height ?? 1.5);
    final double vPad = _multiline ? 12 : ((widget.size.height - lineHeight) / 2).clamp(4.0, 24.0);

    final Widget? suffix = _buildSuffix(c);
    final Widget? prefix = _buildPrefix(c, t);

    final Widget field = MouseRegion(
      cursor: enabled ? SystemMouseCursors.text : SystemMouseCursors.basic,
      child: _HoverBorder(
        enabled: enabled && !_readOnly,
        forcedHover: preview?.hovered ?? false,
        builder: (bool hovered) => TextField(
          controller: _controller,
          focusNode: _focus,
          enabled: enabled,
          readOnly: _readOnly,
          autofocus: widget.autofocus,
          obscureText: widget.variant == AppTextFieldVariant.password,
          enableSuggestions: widget.variant != AppTextFieldVariant.password,
          autocorrect: widget.variant != AppTextFieldVariant.password,
          minLines: _multiline ? 2 : 1,
          maxLines: _multiline ? 6 : 1,
          maxLength: widget.maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          inputFormatters: widget.inputFormatters,
          keyboardType:
              widget.keyboardType ??
              switch (widget.variant) {
                AppTextFieldVariant.number => const TextInputType.numberWithOptions(decimal: true),
                AppTextFieldVariant.multiline => TextInputType.multiline,
                _ => TextInputType.text,
              },
          textInputAction: widget.textInputAction,
          autofillHints: widget.autofillHints,
          style: textStyle,
          cursorColor: c.primaryText,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: enabled ? c.surface : c.disabledBg,
            hintText: widget.hint,
            hintStyle: textStyle.copyWith(color: c.textTertiary),
            counterText: '',
            contentPadding: EdgeInsets.symmetric(horizontal: widget.size.horizontalPadding, vertical: vPad),
            prefixIcon: prefix,
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            border: border(c.borderStrong, 1),
            enabledBorder: _hasError
                ? border(c.error, 2)
                : focused
                ? border(c.primaryText, 2)
                : border(hovered ? c.textSecondary : c.borderStrong, 1),
            focusedBorder: border(_hasError ? c.error : c.primaryText, 2),
            disabledBorder: border(c.disabledText, 1),
          ),
        ),
      ),
    );

    final int length = _controller.text.characters.length;
    final bool showCounter = _multiline && widget.maxLength != null;
    final String? below = widget.errorText ?? widget.helper;

    final Widget column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.label != null) ...<Widget>[
          ExcludeSemantics(
            child: Text(widget.label!, style: t.label.copyWith(color: labelColor)),
          ),
          const SizedBox(height: 4),
        ],
        CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            // Esc снимает фокус (Windows, 03 §9.3).
            const SingleActivator(LogicalKeyboardKey.escape): _focus.unfocus,
          },
          child: field,
        ),
        if (below != null || showCounter) ...<Widget>[
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: below == null
                    ? const SizedBox.shrink()
                    : Semantics(
                        liveRegion: _hasError,
                        child: Text(below, style: t.caption.copyWith(color: _hasError ? c.error : c.textSecondary)),
                      ),
              ),
              if (showCounter)
                Text(
                  '$length/${widget.maxLength}',
                  style: t.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                ),
            ],
          ),
        ],
      ],
    );

    // Узел textField создаёт сам TextField; здесь — подпись и подсказка (03 §9.3, доступность).
    return Semantics(
      label: widget.semanticLabel ?? widget.label,
      hint: widget.helper,
      child: widget.expand ? column : IntrinsicWidth(child: column),
    );
  }

  Widget? _buildPrefix(DsColors c, DsTypography t) {
    if (widget.prefixIcon == null && widget.prefixText == null) {
      return null;
    }
    return Padding(
      padding: EdgeInsetsDirectional.only(start: widget.size.horizontalPadding, end: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.prefixIcon != null)
            Icon(widget.prefixIcon, size: 20, color: widget.enabled ? c.textSecondary : c.disabledText),
          if (widget.prefixIcon != null && widget.prefixText != null) const SizedBox(width: 8),
          if (widget.prefixText != null)
            Text(
              widget.prefixText!,
              style:
                  widget.prefixStyle ??
                  t.bodyLgMedium.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
            ),
        ],
      ),
    );
  }

  Widget? _buildSuffix(DsColors c) {
    final List<Widget> items = <Widget>[];
    if (widget.loading) {
      items.add(const AppProgress.circular(size: 16));
    } else if (_hasError) {
      items.add(Icon(Icons.error_outline_rounded, size: 16, color: c.error));
    }
    if (widget.withClear && widget.enabled && !_readOnly && _controller.text.isNotEmpty) {
      final l10n = AppLocalizations.of(context);
      items.add(
        Semantics(
          button: true,
          label: l10n.ds_button_close,
          excludeSemantics: true,
          child: DsInteractive(
            onTap: () {
              _controller.clear();
              widget.onChanged?.call('');
            },
            builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
              minWidth: 40,
              minHeight: 40,
              child: Icon(Icons.close_rounded, size: 20, color: c.textSecondary),
            ),
          ),
        ),
      );
    }
    if (widget.suffix != null) {
      items.add(widget.suffix!);
    }
    if (items.isEmpty) {
      return null;
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8, end: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < items.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: 4), items[i]],
        ],
      ),
    );
  }
}

/// Отслеживает наведение указателя для обводки hover (`textSecondary`, 03 §9.3).
class _HoverBorder extends StatefulWidget {
  const _HoverBorder({required this.enabled, required this.forcedHover, required this.builder});

  final bool enabled;
  final bool forcedHover;
  final Widget Function(bool hovered) builder;

  @override
  State<_HoverBorder> createState() => _HoverBorderState();
}

class _HoverBorderState extends State<_HoverBorder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(widget.enabled && (_hovered || widget.forcedHover)),
    );
  }
}
