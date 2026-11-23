import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Состояние узла `CheckoutStepper` (03 §9.32).
enum CheckoutStepState {
  /// Выполнен: круг `success` + `check` `onSuccess`; кликабелен.
  done,

  /// Текущий: пилюля `primaryContainer`, цифра и подпись `label 600`.
  current,

  /// Предстоящий: круг с обводкой `borderStrong`, цифра `textSecondary`.
  upcoming,

  /// Ошибка валидации: круг `error` + иконка `error`; тап — к ошибке.
  error,
}

/// Вариант `CheckoutStepper` (03 §9.32): `horizontal` — expanded/medium (56 lp), `compact` — строка
/// «Шаг N из M · Название» + `AppProgress.linear` 4 lp (40 lp). `horizontal`, которому не хватает ширины, сам
/// убирает подписи предстоящих и выполненных узлов, а если и так не помещается — показывает строку `compact`.
enum CheckoutStepperVariant { horizontal, compact }

/// Узел степпера.
@immutable
final class CheckoutStepperItem {
  /// Создаёт узел.
  const CheckoutStepperItem({required this.label, required this.state});

  /// Подпись («Клиент»).
  final String label;

  /// Состояние.
  final CheckoutStepState state;
}

/// Степпер оформления `CheckoutStepper` (03 §9.32; 02 UI-21-002): «Клиент · Получение · Оплата · Завершение»
/// (в режиме клиента — три шага). На expanded/medium все узлы кликабельны (якорная навигация к секции); на compact
/// кликабельны выполненные и с ошибкой (возврат без потери данных). Тексты — от вызывающего кода (ARB).
class CheckoutStepper extends StatelessWidget {
  /// Создаёт степпер.
  const CheckoutStepper({
    super.key,
    required this.steps,
    this.variant = CheckoutStepperVariant.horizontal,
    this.compactLabel,
    this.onStepTap,
    this.allClickable = false,
  });

  /// Узлы по порядку.
  final List<CheckoutStepperItem> steps;

  /// Вариант.
  final CheckoutStepperVariant variant;

  /// Строка compact-варианта («Шаг 2 из 4 · Получение», ключ ARB `checkout_step_counter`).
  final String? compactLabel;

  /// Тап по узлу (индекс).
  final ValueChanged<int>? onStepTap;

  /// Кликабельны все узлы (expanded: одноэкранная форма, степпер — якоря секций).
  final bool allClickable;

  int get _current {
    final int i = steps.indexWhere((CheckoutStepperItem s) => s.state == CheckoutStepState.current);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) =>
      variant == CheckoutStepperVariant.compact ? _compact(context, label: compactLabel ?? '') : _horizontal(context);

  Widget _compact(BuildContext context, {required String label}) {
    final DsColors c = context.colors;
    final int n = steps.length;
    final double value = n == 0 ? 0 : (_current + 1) / n;
    return SizedBox(
      height: 40,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
            ),
          ),
          const SizedBox(height: 8),
          AppProgress.linear(value: value, color: c.primaryText, showAfter: Duration.zero),
        ],
      ),
    );
  }

  /// Ширина узла: поля 8 + 8, круг 28, зазор 8, подпись [label] (`label`, 600 у текущего).
  double _nodeWidth(BuildContext context, int index, {required bool withLabel}) {
    if (!withLabel) {
      return 16 + 28;
    }
    final CheckoutStepperItem s = steps[index];
    final TextStyle style = context.text.label.copyWith(
      fontWeight: s.state == CheckoutStepState.current ? FontWeight.w600 : FontWeight.w500,
    );
    return 16 + 28 + 8 + dsTextWidth(context, s.label, style);
  }

  Widget _horizontal(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      // Указание владельца 2026-11-18 (15 §5.8 (3); 03 §9.32, §8.8): узлы с подписями не помещаются
      // (окно 600 и масштаб текста 1,3) — подпись остаётся у текущего и шага с ошибкой, у остальных — номер или
      // галочка (подпись — в `Semantics`); не помещаются и так — строка «Шаг N из M · Название» (compact).
      final double lines = (steps.length - 1) * 24; // money-double: allow — поля и минимум линий, lp
      double need(bool Function(int i) labelled) {
        double sum = lines;
        for (int i = 0; i < steps.length; i++) {
          sum += _nodeWidth(context, i, withLabel: labelled(i));
        }
        return sum;
      }

      bool full(int i) => true;
      bool short(int i) => steps[i].state == CheckoutStepState.current || steps[i].state == CheckoutStepState.error;
      if (!box.hasBoundedWidth || need(full) <= box.maxWidth) {
        return _horizontalRow(context, full);
      }
      if (need(short) <= box.maxWidth) {
        return _horizontalRow(context, short);
      }
      final CheckoutStepperItem current = steps[_current];
      return _compact(
        context,
        label:
            compactLabel ??
            AppLocalizations.of(context).checkout_step_counter_n('${_current + 1}', current.label, '${steps.length}'),
      );
    },
  );

  Widget _horizontalRow(BuildContext context, bool Function(int i) labelled) {
    final DsColors c = context.colors;
    final List<Widget> row = <Widget>[];
    for (int i = 0; i < steps.length; i++) {
      if (i > 0) {
        final bool doneLine = steps[i - 1].state == CheckoutStepState.done;
        row.add(
          Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: doneLine ? c.success : c.border,
            ),
          ),
        );
      }
      row.add(_node(context, i, withLabel: labelled(i)));
    }
    return SizedBox(height: 56, child: Row(children: row));
  }

  Widget _node(BuildContext context, int index, {bool withLabel = true}) {
    final DsColors c = context.colors;
    final CheckoutStepperItem s = steps[index];
    final bool clickable =
        onStepTap != null && (allClickable || s.state == CheckoutStepState.done || s.state == CheckoutStepState.error);
    final String number = '${index + 1}';
    final Widget circle = switch (s.state) {
      CheckoutStepState.done => _circle(c.success, null, Icon(Icons.check_rounded, size: 16, color: c.onSuccess)),
      CheckoutStepState.error => _circle(c.error, null, Icon(Icons.priority_high_rounded, size: 16, color: c.onError)),
      CheckoutStepState.current => _circle(
        c.primaryContainer,
        c.primaryText,
        Text(
          number,
          style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.primaryText),
        ),
      ),
      CheckoutStepState.upcoming => _circle(
        c.surface,
        c.borderStrong,
        Text(number, style: context.text.label.copyWith(color: c.textSecondary)),
      ),
    };
    final Color labelColor = switch (s.state) {
      CheckoutStepState.error => c.error,
      CheckoutStepState.upcoming => c.textSecondary,
      _ => c.textPrimary,
    };
    final Widget content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: s.state == CheckoutStepState.current
          ? BoxDecoration(color: c.primaryContainer, borderRadius: BorderRadius.all(context.radii.full))
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          circle,
          if (withLabel) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              s.label,
              style: context.text.label.copyWith(
                fontWeight: s.state == CheckoutStepState.current ? FontWeight.w600 : FontWeight.w500,
                color: labelColor,
              ),
            ),
          ],
        ],
      ),
    );
    final String a11yState = switch (s.state) {
      CheckoutStepState.done => '✓',
      CheckoutStepState.current => '•',
      CheckoutStepState.error => '!',
      CheckoutStepState.upcoming => '',
    };
    return Semantics(
      key: ValueKey<String>('checkout-step-$index'),
      button: clickable,
      selected: s.state == CheckoutStepState.current,
      label: '${index + 1}/${steps.length} ${s.label} $a11yState'.trim(),
      excludeSemantics: true,
      child: clickable
          ? DsInteractive(
              onTap: () => onStepTap!(index),
              builder: (BuildContext context, DsInteractionState st) => DsFocusRing(
                visible: st.focused,
                borderRadius: BorderRadius.all(context.radii.full),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: st.hovered ? c.surfaceHover : null,
                    borderRadius: BorderRadius.all(context.radii.full),
                  ),
                  child: content,
                ),
              ),
            )
          : content,
    );
  }

  Widget _circle(Color fill, Color? border, Widget child) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: fill,
      border: border == null ? null : Border.all(color: border, width: 1.5),
    ),
    child: child,
  );
}
