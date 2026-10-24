import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/unit_selector.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Результат проверки ввода нампада (правила задаёт вызывающий: 10 INV-001…010, INV-042).
@immutable
class NumpadValidation {
  /// Создаёт результат.
  const NumpadValidation({this.error, this.hint, this.roundUpLabel, this.roundUpInput, this.canSubmit = true});

  /// Текст ошибки (`error`, «Готово» недоступна).
  final String? error;

  /// Подсказка правил («Кратность: 12 шт · Мин. партия: 12 шт · Доступно: 240 шт»).
  final String? hint;

  /// «Округлить до 36» (UI-16-009).
  final String? roundUpLabel;

  /// Значение, которое подставляет «Округлить».
  final String? roundUpInput;

  /// «Готово» доступна.
  final bool canSubmit;
}

/// Пересчёт дисплея при смене единицы (INV-003): новое значение и подсказка «3 кор = 36 шт».
typedef NumpadUnitConversion = ({String input, String? hint});

/// Итог нампада: введённая строка (с «,» как в дисплее) и выбранная единица.
@immutable
class QuantityNumpadResult {
  /// Создаёт итог.
  const QuantityNumpadResult({required this.input, required this.unitId});

  /// Значение дисплея («12,5»).
  final String input;

  /// [UnitOption.id] выбранной единицы.
  final String unitId;
}

/// Ввод количества `QuantityNumpadSheet` (03 §9.21; SCR-16, INV-041): заголовок → `UnitSelector` →
/// дисплей `display 32/700 tnum` (+ единица), подсказка/ошибка `caption` → «Округлить до N» →
/// быстрые «+10/+50/+100» → клавиши 3×4 (`,` — только при точности > 0) → «Отмена»/«Готово».
/// Первая цифра заменяет текущее значение; ввод ограничен 6 цифрами целой части и точностью единицы;
/// аппаратная клавиатура (цифры, «,»/«.», Backspace, Enter, Esc) работает параллельно.
/// Проверку и пересчёт выполняет вызывающий ([validate], [convert], [quickAdd]); компонент не
/// знает о деньгах и не использует `double` (D-19).
class QuantityNumpadSheet extends StatefulWidget {
  /// Создаёт нампад.
  const QuantityNumpadSheet({
    super.key,
    required this.title,
    required this.initialInput,
    required this.units,
    required this.selectedUnitId,
    required this.decimalsFor,
    required this.validate,
    this.subtitle,
    this.unitLabelFor,
    this.convert,
    this.quickAdd,
    this.quickCounts = const <int>[10, 50, 100],
    this.onDone,
    this.onCancel,
  });

  /// «Количество · Смеситель Gappo G1007».
  final String title;

  /// «Арт. G1007 · 1 650 сом / шт».
  final String? subtitle;

  /// Текущее значение (выделено для замены).
  final String initialInput;

  /// Единицы и упаковки (скрыт при одной).
  final List<UnitOption> units;

  /// Выбранная единица.
  final String selectedUnitId;

  /// Допустимое число знаков после запятой для единицы (упаковки — 0, INV-006).
  final int Function(String unitId) decimalsFor;

  /// Подпись единицы рядом с дисплеем; по умолчанию [UnitOption.label].
  final String Function(String unitId)? unitLabelFor;

  /// Проверка после каждого символа.
  final NumpadValidation Function(String input, String unitId) validate;

  /// Пересчёт при смене единицы; по умолчанию значение сохраняется.
  final NumpadUnitConversion Function(String input, String fromUnitId, String toUnitId)? convert;

  /// Быстрое приращение: новое значение или `null` (кнопка недоступна — превышение доступного).
  final String? Function(String input, String unitId, int count)? quickAdd;

  /// Быстрые кнопки.
  final List<int> quickCounts;

  /// «Готово» (вне [show] — встроенное использование).
  final ValueChanged<QuantityNumpadResult>? onDone;

  /// «Отмена».
  final VoidCallback? onCancel;

  /// Максимум цифр целой части (INV-010: 999 999,999).
  static const int maxIntegerDigits = 6;

  /// Показывает нампад: compact — нижний лист, medium — диалог 400, expanded — диалог 300
  /// (popover у степпера — R2 доработка якоря). Результат — `null` при отмене.
  static Future<QuantityNumpadResult?> show(
    BuildContext context, {
    required String title,
    required String initialInput,
    required List<UnitOption> units,
    required String selectedUnitId,
    required int Function(String unitId) decimalsFor,
    required NumpadValidation Function(String input, String unitId) validate,
    String? subtitle,
    String Function(String unitId)? unitLabelFor,
    NumpadUnitConversion Function(String input, String fromUnitId, String toUnitId)? convert,
    String? Function(String input, String unitId, int count)? quickAdd,
  }) {
    Widget sheet(BuildContext ctx) => QuantityNumpadSheet(
      title: title,
      subtitle: subtitle,
      initialInput: initialInput,
      units: units,
      selectedUnitId: selectedUnitId,
      decimalsFor: decimalsFor,
      unitLabelFor: unitLabelFor,
      validate: validate,
      convert: convert,
      quickAdd: quickAdd,
      onDone: (QuantityNumpadResult r) => Navigator.of(ctx).pop(r),
      onCancel: () => Navigator.of(ctx).pop(),
    );
    final WindowClass wc = context.windowClass;
    if (wc == WindowClass.compact) {
      return AppBottomSheet.show<QuantityNumpadResult>(
        context,
        variant: AppBottomSheetVariant.fullHeight,
        body: Builder(builder: sheet),
      );
    }
    final DsColors c = context.colors;
    return showGeneralDialog<QuantityNumpadResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: AppLocalizations.of(context).ds_button_close,
      barrierColor: c.overlay,
      transitionDuration: context.motion.of(DsAnimations.dialog.duration),
      pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: wc == WindowClass.medium ? 400 : 340,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.all(ctx.radii.lg),
              boxShadow: ctx.elevation.e2,
            ),
            child: SingleChildScrollView(child: sheet(ctx)),
          ),
        ),
      ),
      transitionBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b, Widget child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween<double>(begin: 0.96, end: 1).animate(a), child: child),
      ),
    );
  }

  @override
  State<QuantityNumpadSheet> createState() => _QuantityNumpadSheetState();
}

class _QuantityNumpadSheetState extends State<QuantityNumpadSheet> {
  late String _input = widget.initialInput;
  late String _unitId = widget.selectedUnitId;
  bool _replace = true;
  String? _conversionHint;
  int _shake = 0;
  final FocusNode _focus = FocusNode(debugLabel: 'numpad');

  int get _decimals => widget.decimalsFor(_unitId);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  NumpadValidation get _validation => widget.validate(_input, _unitId);

  void _setInput(String value) {
    final bool hadError = _validation.error != null;
    setState(() {
      _input = value;
      _replace = false;
      _conversionHint = null;
    });
    if (!hadError && _validation.error != null) setState(() => _shake++);
  }

  void _digit(String d) {
    String base = _replace ? '' : _input;
    final int comma = base.indexOf(',');
    if (comma >= 0) {
      if (base.length - comma - 1 >= _decimals) return;
    } else {
      final String digits = base == '0' ? '' : base;
      if (digits.length >= QuantityNumpadSheet.maxIntegerDigits) return;
      base = digits;
    }
    _setInput('$base$d');
  }

  void _comma() {
    if (_decimals == 0) return;
    final String base = _replace ? '0' : (_input.isEmpty ? '0' : _input);
    if (base.contains(',')) return;
    _setInput('$base,');
  }

  void _backspace() {
    if (_replace) {
      _setInput('');
      return;
    }
    if (_input.isEmpty) return;
    _setInput(_input.substring(0, _input.length - 1));
  }

  void _changeUnit(String to) {
    final String from = _unitId;
    final NumpadUnitConversion? r = widget.convert?.call(_input, from, to);
    setState(() {
      _unitId = to;
      if (r != null) {
        _input = r.input;
        _conversionHint = r.hint;
      }
      _replace = true;
    });
  }

  void _submit() {
    final NumpadValidation v = _validation;
    if (!v.canSubmit || v.error != null || _input.isEmpty) {
      setState(() => _shake++);
      return;
    }
    widget.onDone?.call(QuantityNumpadResult(input: _input, unitId: _unitId));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey k = e.logicalKey;
    final String? ch = e.character;
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    if (ch == ',' || ch == '.' || k == LogicalKeyboardKey.numpadDecimal) {
      _comma();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      widget.onCancel?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final NumpadValidation v = _validation;
    final String unitLabel =
        widget.unitLabelFor?.call(_unitId) ??
        widget.units.where((UnitOption o) => o.id == _unitId).firstOrNull?.label ??
        '';
    final bool hasError = v.error != null;
    final String shown = _input.isEmpty ? '0' : _input;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        key: const ValueKey<String>('quantity-numpad'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              widget.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.text.title.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
            ),
          ),
          if (widget.subtitle != null)
            Text(
              widget.subtitle!,
              style: context.text.caption.copyWith(
                color: c.textSecondary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          if (widget.units.length > 1) ...<Widget>[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: UnitSelector(
                options: widget.units,
                selectedId: _unitId,
                onChanged: _changeUnit,
                semanticLabel: l10n.product_unit_title,
              ),
            ),
          ],
          const SizedBox(height: 12),
          DsShake(
            trigger: _shake,
            child: Semantics(
              liveRegion: true,
              label: '$shown $unitLabel',
              excludeSemantics: true,
              child: Container(
                key: const ValueKey<String>('quantity-numpad-display'),
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(context.radii.sm),
                  border: Border.all(color: hasError ? c.error : c.border, width: hasError ? 2 : 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      color: _replace && _input.isNotEmpty ? c.primaryContainer : null,
                      child: Text(
                        shown,
                        style: context.text.display.copyWith(
                          color: hasError ? c.error : c.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(unitLabel, style: context.text.bodyLg.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _message(context, v),
          if (widget.quickAdd != null) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                for (final int n in widget.quickCounts) ...<Widget>[
                  if (n != widget.quickCounts.first) const SizedBox(width: 8),
                  Expanded(child: _quick(context, n, l10n)),
                ],
              ],
            ),
          ],
          const SizedBox(height: 12),
          _keys(context, l10n),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: AppButton(
                  key: const ValueKey<String>('quantity-numpad-cancel'),
                  label: l10n.ds_button_cancel,
                  onPressed: widget.onCancel,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.l,
                  expand: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppButton(
                  key: const ValueKey<String>('quantity-numpad-done'),
                  label: l10n.ds_button_ok,
                  onPressed: v.canSubmit && !hasError && _input.isNotEmpty ? _submit : null,
                  size: AppButtonSize.l,
                  expand: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, NumpadValidation v) {
    final DsColors c = context.colors;
    final String? text = v.error ?? _conversionHint ?? v.hint;
    if (text == null && v.roundUpLabel == null) return const SizedBox(height: 20);
    final bool err = v.error != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (err) ...<Widget>[Icon(Icons.error_rounded, size: 16, color: c.error), const SizedBox(width: 4)],
        Expanded(
          child: Text(
            text ?? '',
            key: const ValueKey<String>('quantity-numpad-message'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.caption.copyWith(
              color: err ? c.error : c.textSecondary,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (v.roundUpLabel != null && v.roundUpInput != null)
          AppButton(
            key: const ValueKey<String>('quantity-numpad-round-up'),
            label: v.roundUpLabel!,
            onPressed: () => _setInput(v.roundUpInput!),
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
          ),
      ],
    );
  }

  Widget _quick(BuildContext context, int n, AppLocalizations l10n) {
    final String? next = widget.quickAdd?.call(_input, _unitId, n);
    return AppButton(
      label: l10n.qty_quick_add(n),
      onPressed: next == null ? null : () => _setInput(next),
      variant: AppButtonVariant.tonal,
      size: AppButtonSize.s,
      expand: true,
    );
  }

  Widget _keys(BuildContext context, AppLocalizations l10n) {
    final bool comma = _decimals > 0;
    final List<List<String>> rows = <List<String>>[
      <String>['1', '2', '3'],
      <String>['4', '5', '6'],
      <String>['7', '8', '9'],
      <String>[',', '0', '<'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final List<String> row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                for (final String k in row) ...<Widget>[
                  if (k != row.first) const SizedBox(width: 8),
                  Expanded(
                    child: switch (k) {
                      ',' => _NumKey(
                        keyId: 'decimal',
                        label: ',',
                        semantics: l10n.qty_key_decimal_a11y,
                        onTap: comma ? _comma : null,
                      ),
                      '<' => _NumKey(
                        keyId: 'backspace',
                        icon: Icons.backspace_outlined,
                        semantics: l10n.qty_key_backspace_a11y,
                        onTap: _backspace,
                        onLongPress: () => _setInput(''),
                      ),
                      _ => _NumKey(keyId: k, label: k, semantics: l10n.qty_key_digit_a11y(k), onTap: () => _digit(k)),
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _NumKey extends StatelessWidget {
  const _NumKey({required this.keyId, required this.semantics, this.label, this.icon, this.onTap, this.onLongPress});

  final String keyId;
  final String? label;
  final IconData? icon;
  final String semantics;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semantics,
      excludeSemantics: true,
      child: DsInteractive(
        key: ValueKey<String>('numpad-key-$keyId'),
        enabled: enabled,
        onTap: onTap == null
            ? null
            : () {
                unawaited(HapticFeedback.selectionClick());
                onTap!();
              },
        onLongPress: onLongPress,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: BorderRadius.all(context.radii.sm),
          child: AnimatedScale(
            scale: s.pressed && !context.motion.reduceMotion ? 0.96 : 1,
            duration: context.motion.of(const Duration(milliseconds: 150)),
            child: Container(
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: !enabled
                    ? c.disabledBg
                    : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surfaceVariant)),
                borderRadius: BorderRadius.all(context.radii.sm),
              ),
              child: icon != null
                  ? Icon(icon, size: 24, color: enabled ? c.textPrimary : c.disabledText)
                  : Text(
                      label ?? '',
                      style: context.text.h3.copyWith(
                        color: enabled ? c.textPrimary : c.disabledText,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
