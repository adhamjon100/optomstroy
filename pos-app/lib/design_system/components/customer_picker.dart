import 'package:flutter/material.dart' hide SearchBar;
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Вариант `CustomerPicker` (03 §9.35): `inline` — секция «Клиент» SCR-21 expanded/medium; `sheet` — содержимое
/// `AppBottomSheet` на compact (раскладка та же, список прокручивается).
enum CustomerPickerVariant { inline, sheet }

/// Состояние списка результатов.
enum CustomerPickerStatus {
  /// Поиск не начат (меньше порога символов роли).
  idle,

  /// Идёт запрос — 3 скелетон-строки 56.
  loading,

  /// Есть результаты.
  results,

  /// Ничего не найдено.
  empty,

  /// Ошибка запроса — «Повторить».
  error,

  /// Нет сети — поиск недоступен (кэша клиентов на устройстве нет, DS-093).
  offline,
}

/// Строка результата поиска (данные — готовыми строками; FL-05: компонент не знает `Customer`).
@immutable
final class CustomerPickerEntry {
  /// Создаёт строку.
  const CustomerPickerEntry({
    required this.id,
    required this.title,
    this.phone,
    this.debtLabel,
    this.overdue = false,
    this.discountLabel,
    this.pendingLabel,
  });

  /// ID клиента.
  final String id;

  /// Имя.
  final String title;

  /// Телефон (`caption tnum`).
  final String? phone;

  /// Индикатор долга без суммы («Есть долг» / «Просрочка»); `null` — без индикатора.
  final String? debtLabel;

  /// Просрочка (`error`), иначе `warning`.
  final bool overdue;

  /// «Скидка 5 %».
  final String? discountLabel;

  /// «Ожидает 1С».
  final String? pendingLabel;
}

/// Поиск и выбор клиента `CustomerPicker` (03 §9.35; 02 UI-21-003, UI-21-023, UI-21-004): чип «Розничный
/// покупатель» → `SearchBar.customers` → список ≤ 6 строк по 56 → «+ Новый клиент». Debounce, порог по роли и
/// запросы — у вызывающего кода; компонент сообщает ввод и выбор.
class CustomerPicker extends StatelessWidget {
  /// Создаёт поиск клиента.
  const CustomerPicker({
    super.key,
    required this.placeholder,
    required this.status,
    required this.entries,
    required this.onSelect,
    this.variant = CustomerPickerVariant.inline,
    this.controller,
    this.focusNode,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.retailLabel,
    this.retailSelected = false,
    this.onRetail,
    this.newCustomerLabel,
    this.onNewCustomer,
    this.emptyText,
    this.errorText,
    this.offlineText,
    this.onRetry,
    this.retryLabel,
    this.maxVisible = 6,
  });

  /// Плейсхолдер поля («Введите имя, телефон или часть имени…»).
  final String placeholder;

  /// Состояние списка.
  final CustomerPickerStatus status;

  /// Результаты.
  final List<CustomerPickerEntry> entries;

  /// Выбор клиента (ID).
  final ValueChanged<String> onSelect;

  /// Вариант.
  final CustomerPickerVariant variant;

  /// Контроллер поля.
  final TextEditingController? controller;

  /// Фокус поля.
  final FocusNode? focusNode;

  /// Подсказка под полем (`seller`: «Введите полный номер или код клиента»).
  final String? hint;

  /// Ввод.
  final ValueChanged<String>? onChanged;

  /// `Enter` — выбрать первую строку.
  final ValueChanged<String>? onSubmitted;

  /// Чип «Розничный покупатель» (`null` — без чипа).
  final String? retailLabel;

  /// Чип выбран.
  final bool retailSelected;

  /// Выбор «Розничного покупателя».
  final VoidCallback? onRetail;

  /// «+ Новый клиент» (`null` — без кнопки).
  final String? newCustomerLabel;

  /// Переход к SCR-26; `null` при заданной подписи — кнопка недоступна (офлайн).
  final VoidCallback? onNewCustomer;

  /// «Клиенты не найдены по «…»».
  final String? emptyText;

  /// «Не удалось найти клиентов».
  final String? errorText;

  /// «Поиск клиентов доступен только онлайн».
  final String? offlineText;

  /// «Повторить».
  final VoidCallback? onRetry;

  /// Подпись «Повторить».
  final String? retryLabel;

  /// Строк без прокрутки.
  final int maxVisible;

  /// Высота строки результата.
  static const double rowHeight = 56;

  /// Ширина строки, с которой бейдж скидки показывается чипом (иначе — во второй строке).
  static const double wideRowMinWidth = 420;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (retailLabel != null) ...<Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: CategoryChip(
              key: const ValueKey<String>('customer-picker-retail'),
              label: retailLabel!,
              selected: retailSelected,
              variant: CategoryChipVariant.choice,
              onTap: onRetail,
            ),
          ),
          const SizedBox(height: 8),
        ],
        SearchBar(
          key: const ValueKey<String>('customer-picker-field'),
          variant: SearchBarVariant.customers,
          controller: controller,
          focusNode: focusNode,
          placeholder: placeholder,
          semanticLabel: placeholder,
          loading: status == CustomerPickerStatus.loading,
          onChanged: status == CustomerPickerStatus.offline ? null : onChanged,
          onSubmitted: onSubmitted,
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(hint!, style: context.text.caption.copyWith(color: c.textSecondary)),
          ),
        _results(context),
        if (newCustomerLabel != null) ...<Widget>[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              key: const ValueKey<String>('customer-picker-new'),
              label: newCustomerLabel!,
              icon: Icons.person_add_alt_rounded,
              variant: AppButtonVariant.outlined,
              onPressed: onNewCustomer,
            ),
          ),
        ],
      ],
    );
  }

  Widget _results(BuildContext context) {
    final DsColors c = context.colors;
    switch (status) {
      case CustomerPickerStatus.idle:
        return const SizedBox.shrink();
      case CustomerPickerStatus.loading:
        const Widget skeleton = SizedBox(
          height: rowHeight,
          child: Row(
            children: <Widget>[
              SkeletonBox.avatar(size: 32),
              SizedBox(width: 12),
              Expanded(child: SkeletonBox.text()),
            ],
          ),
        );
        return const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Column(children: <Widget>[skeleton, skeleton, skeleton]),
        );
      case CustomerPickerStatus.empty:
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(emptyText ?? '', style: context.text.body.copyWith(color: c.textSecondary)),
        );
      case CustomerPickerStatus.error:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ErrorState.inline(message: errorText ?? '', onRetry: onRetry),
        );
      case CustomerPickerStatus.offline:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(offlineText ?? '', style: context.text.caption.copyWith(color: c.textSecondary)),
        );
      case CustomerPickerStatus.results:
        final Widget list = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[for (final CustomerPickerEntry e in entries) _row(context, e)],
        );
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: entries.length > maxVisible && variant == CustomerPickerVariant.inline
                ? ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: rowHeight * maxVisible),
                    child: SingleChildScrollView(child: list),
                  )
                : list,
          ),
        );
    }
  }

  Widget _row(BuildContext context, CustomerPickerEntry e) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      label: <String>[e.title, ?e.phone, ?e.debtLabel].join(', '),
      excludeSemantics: true,
      child: DsInteractive(
        key: ValueKey<String>('customer-picker-row-${e.id}'),
        onTap: () => onSelect(e.id),
        builder: (BuildContext context, DsInteractionState s) => Container(
          height: rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: s.pressed ? c.surfacePressed : (s.hovered || s.focused ? c.surfaceHover : null),
            borderRadius: BorderRadius.all(context.radii.sm),
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              // Узкая колонка (popover 360, зона «Клиент» SCR-21) — бейдж скидки во второй строке, а не чипом.
              final bool wide = box.maxWidth >= wideRowMinWidth;
              final String? second = <String>[?e.phone, if (!wide) ?e.discountLabel].join(' · ').nullIfEmpty;
              return Row(
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: c.surfaceVariant),
                    child: Text(
                      e.title.isEmpty ? '?' : e.title.characters.first.toUpperCase(),
                      style: context.text.caption.copyWith(fontWeight: FontWeight.w600, color: c.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.body.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                        ),
                        if (second != null)
                          Text(
                            second,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.caption.copyWith(
                              color: c.textSecondary,
                              fontFeatures: DsTypography.numeric,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (e.pendingLabel != null) ...<Widget>[
                    StatusChip(label: e.pendingLabel!, variant: StatusChipVariant.info, dense: true),
                    const SizedBox(width: 4),
                  ],
                  if (e.discountLabel != null && wide) ...<Widget>[
                    StatusChip(label: e.discountLabel!, variant: StatusChipVariant.neutral, dense: true),
                    const SizedBox(width: 4),
                  ],
                  if (e.debtLabel != null)
                    StatusChip(
                      label: e.debtLabel!,
                      variant: e.overdue ? StatusChipVariant.error : StatusChipVariant.warning,
                      dense: true,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
