import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Шапка панели фильтров: «Фильтры» `h3` + бейдж числа активных + «Сбросить» + крестик (UI-13-001).
class _FilterHeader extends StatelessWidget {
  const _FilterHeader({
    required this.title,
    required this.activeCount,
    required this.resetLabel,
    required this.onReset,
    required this.closeLabel,
    required this.onClose,
  });

  final String title;
  final int activeCount;
  final String resetLabel;
  final VoidCallback? onReset;
  final String closeLabel;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      height: 56,
      padding: EdgeInsetsDirectional.only(start: context.space.s4, end: context.space.s1),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.h3.copyWith(color: c.textPrimary),
              ),
            ),
          ),
          if (activeCount > 0) ...<Widget>[
            SizedBox(width: context.space.s2),
            AppBadge(count: activeCount, tone: AppBadgeTone.cart),
          ],
          const Spacer(),
          AppButton(
            label: resetLabel,
            onPressed: activeCount > 0 ? onReset : null,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
          ),
          if (onClose != null) AppIconButton(icon: Icons.close_rounded, semanticLabel: closeLabel, onPressed: onClose),
        ],
      ),
    );
  }
}

/// Панель фильтров `FilterPanel` (03 §9.25; 02 SCR-13, expanded): 320 lp внутри контент-колонки,
/// без затемнения; применение — мгновенное (debounce у вызывающего).
class FilterPanel extends StatelessWidget {
  /// Создаёт панель.
  const FilterPanel({
    super.key,
    required this.title,
    required this.sections,
    required this.resetLabel,
    required this.closeLabel,
    this.activeCount = 0,
    this.onReset,
    this.onClose,
    this.note,
    this.width = 320,
  });

  /// «Фильтры».
  final String title;

  /// Секции ([FilterSection]).
  final List<Widget> sections;

  /// «Сбросить».
  final String resetLabel;

  /// «Закрыть».
  final String closeLabel;

  /// Число активных фильтров (бейдж).
  final int activeCount;

  /// Сброс всех фильтров.
  final VoidCallback? onReset;

  /// Скрыть панель (фильтры остаются применёнными).
  final VoidCallback? onClose;

  /// Пометка под шапкой («Фильтры по сохранённым данным от 08:12» `warning`).
  final String? note;

  /// Ширина.
  final double width;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(left: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _FilterHeader(
            title: title,
            activeCount: activeCount,
            resetLabel: resetLabel,
            onReset: onReset,
            closeLabel: closeLabel,
            onClose: onClose,
          ),
          if (note != null) _Note(text: note!),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(bottom: context.space.s4),
              children: sections,
            ),
          ),
        ],
      ),
    );
  }
}

/// Лист фильтров `FilterSheet` (03 §9.25; compact/medium): шапка + прокручиваемые секции +
/// закреплённый футер 72 с «Показать N товаров» (`AppButton.primary L expand`).
class FilterSheet extends StatelessWidget {
  /// Создаёт лист.
  const FilterSheet({
    super.key,
    required this.title,
    required this.sections,
    required this.resetLabel,
    required this.closeLabel,
    required this.applyLabel,
    this.activeCount = 0,
    this.onReset,
    this.onClose,
    this.onApply,
    this.applyLoading = false,
    this.applyHint,
    this.note,
  });

  /// «Фильтры».
  final String title;

  /// Секции.
  final List<Widget> sections;

  /// «Сбросить».
  final String resetLabel;

  /// «Закрыть».
  final String closeLabel;

  /// «Показать 124 товара» / «Нет товаров».
  final String applyLabel;

  /// Число активных фильтров.
  final int activeCount;

  /// Сброс.
  final VoidCallback? onReset;

  /// Закрыть без применения.
  final VoidCallback? onClose;

  /// Применить; `null` — кнопка недоступна (0 товаров, ошибка цены).
  final VoidCallback? onApply;

  /// Идёт подсчёт.
  final bool applyLoading;

  /// Подсказка под кнопкой («Ослабьте условия»).
  final String? applyHint;

  /// Пометка под шапкой.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return ColoredBox(
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _FilterHeader(
            title: title,
            activeCount: activeCount,
            resetLabel: resetLabel,
            onReset: onReset,
            closeLabel: closeLabel,
            onClose: onClose,
          ),
          if (note != null) _Note(text: note!),
          Expanded(child: ListView(children: sections)),
          Container(
            padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s3),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AppButton(
                    key: const ValueKey<String>('filter-sheet-apply'),
                    label: applyLabel,
                    onPressed: onApply,
                    loading: applyLoading,
                    size: AppButtonSize.l,
                    expand: true,
                  ),
                  if (applyHint != null) ...<Widget>[
                    SizedBox(height: context.space.s1),
                    Text(
                      applyHint!,
                      textAlign: TextAlign.center,
                      style: context.text.caption.copyWith(color: c.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Раскрываемая секция фильтров (строки 48; ANIM-016).
class FilterSection extends StatefulWidget {
  /// Создаёт секцию.
  const FilterSection({super.key, required this.title, required this.child, this.initiallyExpanded = true});

  /// Заголовок `label 600`.
  final String title;

  /// Содержимое.
  final Widget child;

  /// Раскрыта при показе.
  final bool initiallyExpanded;

  @override
  State<FilterSection> createState() => _FilterSectionState();
}

class _FilterSectionState extends State<FilterSection> {
  late bool _expanded = widget.initiallyExpanded;

  /// Reduce-motion (нулевая длительность) — без `AnimatedSize` (03 A11Y-006).
  Widget _expandable(Duration d, Widget child) =>
      d == Duration.zero ? child : AnimatedSize(duration: d, alignment: Alignment.topCenter, child: child);

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Duration d = context.motion.of(context.motion.base);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            button: true,
            expanded: _expanded,
            label: widget.title,
            excludeSemantics: true,
            child: DsInteractive(
              onTap: () => setState(() => _expanded = !_expanded),
              builder: (BuildContext context, DsInteractionState s) => Container(
                height: 48,
                color: s.hovered ? c.surfaceHover : Colors.transparent,
                padding: EdgeInsets.symmetric(horizontal: context.space.s4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        widget.title,
                        style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: d,
                      child: Icon(Icons.expand_more_rounded, size: 20, color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _expandable(
            d,
            _expanded
                ? Padding(
                    padding: EdgeInsets.fromLTRB(context.space.s4, 0, context.space.s4, context.space.s3),
                    child: widget.child,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      color: c.warningContainer,
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      child: Text(text, style: context.text.caption.copyWith(color: c.warning)),
    );
  }
}
