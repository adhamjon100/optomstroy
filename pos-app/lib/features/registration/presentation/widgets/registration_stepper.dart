// `RegistrationStepper` (03 §9.66, DS-096; ядро §17.5, §19.3): 3 шага «Данные · Защита входа · Готово»,
// при SCR-06 — 4 шага «Данные · Защита входа · Привязка · Готово». compact — строка «Шаг n из N · Имя» +
// `AppProgress.linear` 4 px; medium+ — горизонтальные узлы. Выполненные шаги кликабельны (возврат без потери
// данных), предстоящие — нет; на «Готово» возврат недоступен (onStepTap = null).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';

class RegistrationStepper extends StatelessWidget {
  const RegistrationStepper({
    super.key,
    required this.current,
    required this.withCustomerLink,
    this.onStepTap,
    this.forceCompact,
  });

  /// Текущий шаг.
  final RegistrationStep current;

  /// `CUSTOMER_SELF_SERVICE=true` (R1 по умолчанию) — шаг «Привязка» входит в индикатор.
  final bool withCustomerLink;

  /// Тап по выполненному шагу (назад к нему).
  final ValueChanged<RegistrationStep>? onStepTap;

  /// Принудительный вариант (тесты); по умолчанию — по классу окна.
  final bool? forceCompact;

  List<RegistrationStep> get steps => <RegistrationStep>[
    RegistrationStep.data,
    RegistrationStep.security,
    if (withCustomerLink) RegistrationStep.customerLink,
    RegistrationStep.done,
  ];

  static String labelOf(AppLocalizations l10n, RegistrationStep step) => switch (step) {
    RegistrationStep.data => l10n.reg_step_data,
    RegistrationStep.security => l10n.reg_step_security,
    RegistrationStep.customerLink => l10n.reg_step_customer_link,
    RegistrationStep.done => l10n.reg_step_done,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final list = steps;
    final index = list.indexOf(current).clamp(0, list.length - 1);
    final compact = forceCompact ?? context.windowClass == WindowClass.compact;
    final caption = l10n.reg_stepper_compact(index + 1, labelOf(l10n, list[index]), '${list.length}');
    if (compact) {
      return Semantics(
        label: caption,
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(caption, style: context.text.label.copyWith(color: context.colors.textSecondary)),
              SizedBox(height: context.space.s2),
              AppProgress.linear(value: (index + 1) / list.length),
            ],
          ),
        ),
      );
    }
    final children = <Widget>[];
    for (var i = 0; i < list.length; i++) {
      if (i > 0) {
        children.add(
          Expanded(
            child: Container(
              height: 2,
              margin: EdgeInsets.symmetric(horizontal: context.space.s2),
              color: i <= index ? context.colors.success : context.colors.border,
            ),
          ),
        );
      }
      children.add(
        _Node(
          number: i + 1,
          label: labelOf(l10n, list[i]),
          state: i < index ? _NodeState.done : (i == index ? _NodeState.active : _NodeState.upcoming),
          onTap: i < index && onStepTap != null && current != RegistrationStep.done ? () => onStepTap!(list[i]) : null,
        ),
      );
    }
    return Semantics(
      label: caption,
      child: Row(children: children),
    );
  }
}

enum _NodeState { done, active, upcoming }

class _Node extends StatelessWidget {
  const _Node({required this.number, required this.label, required this.state, this.onTap});

  final int number;
  final String label;
  final _NodeState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final circleColor = switch (state) {
      _NodeState.done => c.success,
      _NodeState.active => c.primaryText,
      _NodeState.upcoming => Colors.transparent,
    };
    final node = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedContainer(
          duration: context.motion.of(context.motion.fast),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: circleColor,
            border: Border.all(color: state == _NodeState.upcoming ? c.border : circleColor, width: 2),
          ),
          alignment: Alignment.center,
          child: state == _NodeState.done
              ? Icon(Icons.check_rounded, size: 18, color: c.onSuccess)
              : Text(
                  '$number',
                  style: context.text.label.copyWith(color: state == _NodeState.active ? c.onPrimary : c.textSecondary),
                ),
        ),
        SizedBox(width: context.space.s2),
        Text(
          label,
          style: context.text.label.copyWith(color: state == _NodeState.upcoming ? c.textSecondary : c.textPrimary),
        ),
      ],
    );
    if (onTap == null) return ExcludeSemantics(child: node);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.all(context.radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: ExcludeSemantics(child: node),
        ),
      ),
    );
  }
}
