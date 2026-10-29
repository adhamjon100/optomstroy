// Витрина компонентов первой очереди RM-C-003 — общая для `/dev/gallery` (только debug)
// и golden-тестов (test/golden). Тексты — демонстрационные (debug-экран не локализуется;
// компоненты в экранах получают строки из ARB).
import 'package:flutter/material.dart' hide SearchBar;
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_divider.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/nav_destination.dart';
import 'package:optomstroy/design_system/components/navigation_drawer_app.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/option_tile.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/top_app_bar_cart_button.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/layout/adaptive_scaffold.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

/// Раздел витрины.
@immutable
class DsShowcaseSection {
  /// Создаёт раздел.
  const DsShowcaseSection(this.id, this.title, this.builder);

  /// Идентификатор (имя golden-файла).
  final String id;

  /// Заголовок.
  final String title;

  /// Содержимое.
  final WidgetBuilder builder;
}

/// Состояния предпросмотра (03 §10: default / hover / pressed / focused / disabled).
abstract final class DsPreviewStates {
  /// Hover.
  static const DsInteractionState hover = DsInteractionState(hovered: true);

  /// Pressed.
  static const DsInteractionState pressed = DsInteractionState(hovered: true, pressed: true);

  /// Focused (клавиатура).
  static const DsInteractionState focused = DsInteractionState(focused: true);
}

void _noop() {}

void _noopValue<T>(T _) {}

/// Пункты навигации режима `seller` (ядро §9) для витрины.
const List<NavDestination> dsShowcaseDestinations = <NavDestination>[
  NavDestination(icon: Icons.grid_view_outlined, selectedIcon: Icons.grid_view_rounded, label: 'Каталог'),
  NavDestination(icon: Icons.star_outline_rounded, selectedIcon: Icons.star_rounded, label: 'Избранное'),
  NavDestination(
    icon: Icons.shopping_cart_outlined,
    selectedIcon: Icons.shopping_cart_rounded,
    label: 'Корзина',
    badgeCount: 5,
    badgeTone: AppBadgeTone.cart,
  ),
  NavDestination(icon: Icons.group_outlined, selectedIcon: Icons.group_rounded, label: 'Клиенты'),
  NavDestination(
    icon: Icons.account_circle_outlined,
    selectedIcon: Icons.account_circle_rounded,
    label: 'Профиль',
    badgeDot: true,
  ),
];

/// Подпись + пример.
class DsSpecimen extends StatelessWidget {
  /// Создаёт пример.
  const DsSpecimen({super.key, required this.label, required this.child, this.state, this.width});

  /// Подпись (`caption textSecondary`).
  final String label;

  /// Компонент.
  final Widget child;

  /// Принудительное состояние.
  final DsInteractionState? state;

  /// Ширина (по умолчанию — по содержимому).
  final double? width;

  @override
  Widget build(BuildContext context) {
    Widget c = child;
    if (state != null) {
      c = DsStatePreview(state: state!, child: c);
    }
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
          const SizedBox(height: 4),
          c,
        ],
      ),
    );
  }
}

Widget _wrap(List<Widget> children, {double spacing = 16}) =>
    Wrap(spacing: spacing, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.end, children: children);

double _fieldWidth(BuildContext context) => context.windowClass == WindowClass.compact ? double.infinity : 320;

/// Все разделы витрины.
abstract final class DsShowcase {
  /// Разделы в порядке витрины.
  static final List<DsShowcaseSection> sections = <DsShowcaseSection>[
    const DsShowcaseSection('buttons', 'AppButton · AppIconButton', _buttons),
    const DsShowcaseSection('inputs', 'AppTextField · PhoneField · SearchBar · AppDropdown', _inputs),
    const DsShowcaseSection('codes', 'OtpField · PinField', _codes),
    const DsShowcaseSection('selection', 'AppCheckbox · AppRadio · AppSwitch · OptionTile', _selection),
    const DsShowcaseSection('feedback', 'StatusChip · AppBadge · AppProgress · SkeletonBox · AppTooltip', _feedback),
    const DsShowcaseSection('states', 'EmptyState · ErrorState · AppSnackbar', _states),
    const DsShowcaseSection('overlays', 'ConfirmDialog · AppBottomSheet', _overlays),
    const DsShowcaseSection('navigation', 'TopAppBarPos · BottomNavBar · NavigationRailApp · списки', _navigation),
    const DsShowcaseSection('tabs', 'AppTabs', _tabs),
  ];

  static Widget _buttons(BuildContext context) {
    final bool compact = context.windowClass == WindowClass.compact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _wrap(<Widget>[
          const DsSpecimen(
            label: 'primary',
            child: AppButton(label: 'Создать заказ', onPressed: _noop),
          ),
          const DsSpecimen(
            label: 'hover',
            state: DsPreviewStates.hover,
            child: AppButton(label: 'Создать заказ', onPressed: _noop),
          ),
          const DsSpecimen(
            label: 'pressed',
            state: DsPreviewStates.pressed,
            child: AppButton(label: 'Создать заказ', onPressed: _noop),
          ),
          const DsSpecimen(
            label: 'focused',
            state: DsPreviewStates.focused,
            child: AppButton(label: 'Создать заказ', onPressed: _noop),
          ),
          const DsSpecimen(
            label: 'disabled',
            child: AppButton(label: 'Создать заказ', onPressed: null),
          ),
          const DsSpecimen(
            label: 'loading',
            child: AppButton(label: 'Создать заказ', onPressed: _noop, loading: true),
          ),
        ]),
        const SizedBox(height: 16),
        _wrap(<Widget>[
          for (final AppButtonVariant v in AppButtonVariant.values)
            DsSpecimen(
              label: v.name,
              child: AppButton(label: 'Далее', icon: Icons.add_rounded, onPressed: _noop, variant: v),
            ),
          const DsSpecimen(
            label: 'outlined disabled',
            child: AppButton(label: 'Далее', onPressed: null, variant: AppButtonVariant.outlined),
          ),
        ]),
        const SizedBox(height: 16),
        _wrap(<Widget>[
          const DsSpecimen(
            label: 'S 36',
            child: AppButton(label: 'Очистить', onPressed: _noop, size: AppButtonSize.s),
          ),
          const DsSpecimen(
            label: 'M 44',
            child: AppButton(label: 'Далее', onPressed: _noop),
          ),
          DsSpecimen(
            label: 'L 52${compact ? ' · expand' : ''}',
            width: compact ? double.infinity : null,
            child: AppButton(
              label: 'Получить код',
              onPressed: _noop,
              size: AppButtonSize.l,
              expand: compact,
              trailingIcon: Icons.arrow_forward_rounded,
            ),
          ),
        ]),
        const SizedBox(height: 16),
        _wrap(<Widget>[
          for (final AppIconButtonVariant v in AppIconButtonVariant.values)
            DsSpecimen(
              label: v.name,
              child: AppIconButton(
                icon: Icons.delete_outline_rounded,
                semanticLabel: 'Удалить',
                onPressed: _noop,
                variant: v,
              ),
            ),
          const DsSpecimen(
            label: 'selected',
            child: AppIconButton(
              icon: Icons.star_outline_rounded,
              selectedIcon: Icons.star_rounded,
              semanticLabel: 'Избранное',
              onPressed: _noop,
              selected: true,
            ),
          ),
          const DsSpecimen(
            label: 'pressed',
            state: DsPreviewStates.pressed,
            child: AppIconButton(icon: Icons.close_rounded, semanticLabel: 'Закрыть', onPressed: _noop),
          ),
          const DsSpecimen(
            label: 'focused',
            state: DsPreviewStates.focused,
            child: AppIconButton(icon: Icons.close_rounded, semanticLabel: 'Закрыть', onPressed: _noop),
          ),
          const DsSpecimen(
            label: 'disabled',
            child: AppIconButton(icon: Icons.close_rounded, semanticLabel: 'Закрыть', onPressed: null),
          ),
          const DsSpecimen(
            label: 'loading',
            child: AppIconButton(icon: Icons.sync_rounded, semanticLabel: 'Обновить', onPressed: _noop, loading: true),
          ),
          const DsSpecimen(
            label: 'badge',
            child: AppIconButton(
              icon: Icons.notifications_outlined,
              semanticLabel: 'Уведомления, 3',
              onPressed: _noop,
              badge: AppBadge(count: 3),
            ),
          ),
          const DsSpecimen(
            label: 'small',
            child: AppIconButton(icon: Icons.more_vert_rounded, semanticLabel: 'Ещё', onPressed: _noop, small: true),
          ),
        ]),
      ],
    );
  }

  static Widget _inputs(BuildContext context) {
    final double w = _fieldWidth(context);
    return _wrap(<Widget>[
      SizedBox(
        width: w,
        child: const AppTextField(label: 'Имя клиента', hint: 'Например, Азамат', helper: 'Как в документах 1С'),
      ),
      SizedBox(
        width: w,
        child: const DsSpecimen(
          label: 'focused',
          state: DsPreviewStates.focused,
          child: AppTextField(label: 'Артикул', hint: 'Введите артикул'),
        ),
      ),
      SizedBox(
        width: w,
        child: const AppTextField(
          label: 'Количество',
          variant: AppTextFieldVariant.number,
          errorText: 'Больше остатка: доступно 12',
        ),
      ),
      SizedBox(
        width: w,
        child: const AppTextField(label: 'Склад', hint: 'Основной', enabled: false),
      ),
      SizedBox(
        width: w,
        child: const AppTextField(label: 'Штрихкод', hint: '4600000000000', loading: true),
      ),
      SizedBox(
        width: w,
        child: const AppTextField(
          label: 'Комментарий',
          variant: AppTextFieldVariant.multiline,
          maxLength: 200,
          hint: 'Комментарий к заказу',
        ),
      ),
      SizedBox(
        width: w,
        child: const PhoneField(
          semanticLabel: 'Номер телефона',
          label: 'Номер телефона',
          helper: 'Введите 9 цифр после +996',
          variant: PhoneFieldVariant.auth,
          autofocus: false,
        ),
      ),
      SizedBox(
        width: w,
        child: const PhoneField(
          semanticLabel: 'Номер телефона',
          label: 'Телефон получателя',
          errorText: 'Номер должен содержать 9 цифр после +996',
        ),
      ),
      SizedBox(
        width: w,
        child: const SearchBar(onScan: _noop, scannerLabel: 'Сканировать'),
      ),
      SizedBox(
        width: w,
        child: const DsSpecimen(
          label: 'focused · loading',
          state: DsPreviewStates.focused,
          child: SearchBar(loading: true, variant: SearchBarVariant.customers),
        ),
      ),
      SizedBox(
        width: w,
        child: const AppDropdown<String>(
          label: 'Склад',
          value: 'main',
          onChanged: _noopValue<String>,
          items: <AppDropdownItem<String>>[
            AppDropdownItem<String>(value: 'main', label: 'Основной склад'),
            AppDropdownItem<String>(value: 'shop', label: 'Магазин на Ахунбаева'),
          ],
        ),
      ),
      SizedBox(
        width: w,
        child: const AppDropdown<String>(
          label: 'Единица',
          hint: 'Выберите единицу',
          value: null,
          onChanged: _noopValue<String>,
          errorText: 'Выберите единицу',
          items: <AppDropdownItem<String>>[AppDropdownItem<String>(value: 'pc', label: 'шт')],
        ),
      ),
    ]);
  }

  static Widget _codes(BuildContext context) {
    return _wrap(spacing: 32, <Widget>[
      const DsSpecimen(
        label: 'OtpField · idle',
        child: OtpField(semanticLabel: 'Код из SMS, 6 цифр', autofocus: false),
      ),
      const DsSpecimen(
        label: 'OtpField · error',
        child: OtpField(
          semanticLabel: 'Код из SMS, 6 цифр',
          autofocus: false,
          status: CodeFieldStatus.error,
          errorText: 'Неверный код. Осталось попыток: 3',
        ),
      ),
      const DsSpecimen(
        label: 'OtpField · disabled',
        child: OtpField(semanticLabel: 'Код из SMS, 6 цифр', autofocus: false, status: CodeFieldStatus.disabled),
      ),
      DsSpecimen(
        label: 'PinField · enter (6)',
        child: PinField(
          length: 6,
          autofocus: false,
          semanticLabel: (int n, int len) => 'PIN, введено $n из $len',
          backspaceLabel: 'Стереть',
          biometricLabel: 'Биометрия',
          onBiometric: _noop,
        ),
      ),
      DsSpecimen(
        label: 'PinField · error (4)',
        child: PinField(
          length: 4,
          autofocus: false,
          showNumpad: false,
          status: CodeFieldStatus.error,
          errorText: 'Неверный PIN. Осталось попыток: 2',
          semanticLabel: (int n, int len) => 'PIN, введено $n из $len',
          backspaceLabel: 'Стереть',
        ),
      ),
    ]);
  }

  static Widget _selection(BuildContext context) {
    final double w = _fieldWidth(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _wrap(<Widget>[
          const AppCheckbox(value: false, onChanged: _noopValue<bool?>, label: 'Печатать накладную'),
          const AppCheckbox(value: true, onChanged: _noopValue<bool?>, label: 'Выбрано'),
          const AppCheckbox(value: null, tristate: true, onChanged: _noopValue<bool?>, label: 'Все'),
          const AppCheckbox(value: true, onChanged: null, label: 'Недоступно'),
          const AppCheckbox(
            value: false,
            onChanged: _noopValue<bool?>,
            label: 'Согласие на обработку данных',
            errorText: 'Нужно согласие',
          ),
          const DsSpecimen(
            label: 'focused',
            state: DsPreviewStates.focused,
            child: AppCheckbox(value: false, onChanged: _noopValue<bool?>, semanticLabel: 'Чекбокс'),
          ),
        ]),
        const SizedBox(height: 8),
        _wrap(<Widget>[
          const AppRadio<int>(value: 1, groupValue: 1, onChanged: _noopValue<int>, label: 'Клиент'),
          const AppRadio<int>(value: 2, groupValue: 1, onChanged: _noopValue<int>, label: 'Другой человек'),
          const AppRadio<int>(value: 3, groupValue: 1, onChanged: null, label: 'Недоступно'),
        ]),
        const SizedBox(height: 8),
        _wrap(<Widget>[
          SizedBox(
            width: w,
            child: const AppSwitch(value: true, onChanged: _noopValue<bool>, label: 'Сразу в корзину при сканировании'),
          ),
          SizedBox(
            width: w,
            child: const AppSwitch(value: false, onChanged: _noopValue<bool>, label: 'Уменьшить анимации'),
          ),
          SizedBox(
            width: w,
            child: const AppSwitch(value: true, onChanged: _noopValue<bool>, loading: true, label: 'Вход по биометрии'),
          ),
          SizedBox(
            width: w,
            child: const AppSwitch(value: false, onChanged: null, label: 'Недоступно'),
          ),
        ]),
        const SizedBox(height: 16),
        _wrap(<Widget>[
          SizedBox(
            width: w,
            child: const OptionTile(
              title: 'Самовывоз',
              subtitle: 'Со склада магазина',
              icon: Icons.storefront_outlined,
              selected: true,
              onTap: _noop,
            ),
          ),
          SizedBox(
            width: w,
            child: const OptionTile(
              title: 'Доставка курьером',
              subtitle: 'Адрес и время — на следующем шаге',
              icon: Icons.local_shipping_outlined,
              selected: false,
              onTap: _noop,
            ),
          ),
          SizedBox(
            width: w,
            child: const OptionTile(
              title: 'Доставка курьером',
              icon: Icons.local_shipping_outlined,
              selected: false,
              onTap: null,
              disabledReason: 'Доставка недоступна для этого клиента',
            ),
          ),
          SizedBox(
            width: w,
            child: const OptionTile(
              title: 'Самовывоз',
              icon: Icons.storefront_outlined,
              selected: false,
              onTap: _noop,
              errorText: 'Выберите способ получения',
            ),
          ),
          SizedBox(
            width: w,
            child: const OptionTile(
              title: 'Упаковка',
              subtitle: 'Множественный выбор',
              selected: true,
              indicator: OptionTileIndicator.check,
              onTap: _noop,
            ),
          ),
        ]),
      ],
    );
  }

  static Widget _feedback(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _wrap(spacing: 8, <Widget>[
          const StatusChip(label: 'Черновик', variant: StatusChipVariant.neutral),
          const StatusChip(label: 'На согласовании', variant: StatusChipVariant.info),
          const StatusChip(label: 'Согласован', variant: StatusChipVariant.success),
          const StatusChip(label: 'Ожидает оплаты', variant: StatusChipVariant.warning),
          const StatusChip(label: 'Не отправлен', variant: StatusChipVariant.error),
          const StatusChip(label: 'Опт', variant: StatusChipVariant.priceList),
          const StatusChip(label: 'Данные от 09:41', variant: StatusChipVariant.warning, icon: Icons.schedule_rounded),
          const StatusChip(label: 'Компактный', variant: StatusChipVariant.info, dense: true, rounded: false),
        ]),
        const SizedBox(height: 16),
        _wrap(<Widget>[
          const AppBadge(count: 5, tone: AppBadgeTone.cart),
          const AppBadge(count: 12),
          const AppBadge(count: 120),
          const AppBadge.dot(),
          const AppProgress.circular(size: 16),
          const AppProgress.circular(size: 24),
          const AppProgress.circular(size: 48, value: 0.45),
          const SizedBox(width: 160, child: AppProgress.linear(value: 0.6)),
          const SizedBox(width: 160, child: AppProgress.linear(thin: true)),
          const SizedBox(
            width: 240,
            child: AppProgress.stepped(steps: 5, completedSteps: 2, label: 'Товары · 12 400 / 50 000'),
          ),
        ]),
        const SizedBox(height: 16),
        _wrap(<Widget>[
          const SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SkeletonBox.image(semanticLabel: 'Загрузка'),
                SizedBox(height: 8),
                SkeletonBox.text(width: 140),
                SizedBox(height: 4),
                SkeletonBox.text(width: 96, height: 16),
                SizedBox(height: 8),
                SkeletonBox(width: 160, height: 44, radius: Radius.circular(8)),
              ],
            ),
          ),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SkeletonBox.avatar(),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SkeletonBox.text(width: 160),
                  SizedBox(height: 4),
                  SkeletonBox.text(width: 96, height: 16),
                ],
              ),
            ],
          ),
          const DsSpecimen(
            label: 'AppTooltip (hover 500 мс)',
            child: AppTooltip(
              message: 'Смеситель для кухни с гибким изливом, хром',
              child: Text('Смеситель для кухни…'),
            ),
          ),
        ]),
      ],
    );
  }

  static Widget _states(BuildContext context) {
    final bool compact = context.windowClass == WindowClass.compact;
    const Widget empty = EmptyState(
      variant: EmptyStateVariant.search,
      title: 'Ничего не найдено по «кран»',
      body: 'Проверьте запрос или отсканируйте штрихкод',
      actionLabel: 'Сбросить фильтры',
      onAction: _noop,
      secondaryActionLabel: 'Сканировать',
      onSecondaryAction: _noop,
    );
    const Widget full = ErrorState.fullScreen(
      title: '1С временно недоступна',
      message: 'Заказы будут отправлены позже. Продажа в долг недоступна',
      onRetry: _noop,
      onBack: _noop,
      backLabel: 'Назад',
      requestId: 'req-7f3a9c',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const ErrorState.inline(message: 'Не удалось выполнить поиск', onRetry: _noop),
        const SizedBox(height: 8),
        for (final ErrorStateTone t in ErrorStateTone.values) ...<Widget>[
          ErrorState.banner(message: 'Баннер: ${t.name}', tone: t, onClose: _noop),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        if (compact) ...<Widget>[empty, full] else
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: empty),
              Expanded(child: full),
            ],
          ),
        const SizedBox(height: 16),
        const Wrap(
          spacing: 16,
          runSpacing: 16,
          children: <Widget>[
            SizedBox(width: 360, child: AppSnackbar(message: 'Заказ отложен')),
            SizedBox(
              width: 360,
              child: AppSnackbar(
                message: 'Добавлено в корзину',
                variant: AppSnackbarVariant.success,
                actionLabel: 'Отменить',
                onAction: _noop,
              ),
            ),
            SizedBox(
              width: 360,
              child: AppSnackbar(
                message: 'Не удалось сохранить',
                variant: AppSnackbarVariant.error,
                actionLabel: 'Повторить',
                onAction: _noop,
                onClose: _noop,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static Widget _overlays(BuildContext context) {
    final bool compact = context.windowClass == WindowClass.compact;
    final List<Widget> items = <Widget>[
      const ConfirmDialog(
        title: 'Очистить корзину?',
        message: 'Будут удалены 5 позиций',
        confirmLabel: 'Очистить',
        variant: ConfirmDialogVariant.destructive,
      ),
      const ConfirmDialog(
        title: 'Отменить заказ № 1024?',
        message: 'Укажите причину — она уйдёт в 1С',
        confirmLabel: 'Отменить заказ',
        variant: ConfirmDialogVariant.withReason,
        reasonLabel: 'Причина',
        destructiveCta: true,
      ),
      SizedBox(
        width: compact ? double.infinity : 400,
        child: const AppBottomSheet(
          title: 'Сортировка',
          body: Column(
            children: <Widget>[
              AppRadio<int>(value: 1, groupValue: 1, onChanged: _noopValue<int>, label: 'По названию'),
              AppRadio<int>(value: 2, groupValue: 1, onChanged: _noopValue<int>, label: 'Сначала дешёвые'),
            ],
          ),
          footer: AppButton(label: 'Применить', onPressed: _noop, expand: true),
        ),
      ),
      if (!compact)
        const SizedBox(
          height: 320,
          child: AppBottomSheet(
            title: 'Остатки по складам',
            variant: AppBottomSheetVariant.side,
            width: AppBottomSheet.sideMedium,
            body: Text('Основной склад · 12 шт'),
          ),
        ),
    ];
    return Wrap(spacing: 24, runSpacing: 24, children: items);
  }

  /// `AppTabs` (03 §9.49): `fixed` (2–4, счётчик, иконка, disabled), `scrollable` (> 4), `segmented` (фильтры-сегменты
  /// «Мои / Все», «Все · Непрочитанные»), состояния hover / pressed / focused.
  static Widget _tabs(BuildContext context) {
    const List<AppTab<int>> segments = <AppTab<int>>[
      AppTab<int>(value: 0, label: 'Мои'),
      AppTab<int>(value: 1, label: 'Все'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const AppTabs<int>(
          value: 0,
          onChanged: _noopValue<int>,
          tabs: <AppTab<int>>[
            AppTab<int>(value: 0, label: 'Описание'),
            AppTab<int>(value: 1, label: 'Характеристики'),
            AppTab<int>(value: 2, label: 'Склады'),
          ],
        ),
        const SizedBox(height: 16),
        const AppTabs<int>(
          value: 1,
          onChanged: _noopValue<int>,
          tabs: <AppTab<int>>[
            AppTab<int>(value: 0, label: 'Товары', count: 27, icon: Icons.inventory_2_outlined),
            AppTab<int>(value: 1, label: 'Клиенты', count: 12, icon: Icons.people_outline_rounded),
            AppTab<int>(
              value: 2,
              label: 'Долги',
              icon: Icons.lock_outline_rounded,
              enabled: false,
              disabledReason: 'Нужно подтверждение',
            ),
          ],
        ),
        const SizedBox(height: 16),
        const AppTabs<int>(
          variant: AppTabsVariant.scrollable,
          value: 2,
          onChanged: _noopValue<int>,
          tabs: <AppTab<int>>[
            AppTab<int>(value: 0, label: 'Заказы', count: 12),
            AppTab<int>(value: 1, label: 'Долг'),
            AppTab<int>(value: 2, label: 'Скидки'),
            AppTab<int>(value: 3, label: 'Контакты'),
            AppTab<int>(value: 4, label: 'История'),
            AppTab<int>(value: 5, label: 'Документы'),
          ],
        ),
        const SizedBox(height: 16),
        _wrap(const <Widget>[
          AppTabs<int>(variant: AppTabsVariant.segmented, value: 0, onChanged: _noopValue<int>, tabs: segments),
          AppTabs<int>(
            variant: AppTabsVariant.segmented,
            value: 1,
            onChanged: _noopValue<int>,
            tabs: <AppTab<int>>[
              AppTab<int>(value: 0, label: 'Все'),
              AppTab<int>(value: 1, label: 'Непрочитанные (3)'),
            ],
          ),
          AppTabs<int>(
            variant: AppTabsVariant.segmented,
            value: 0,
            enabled: false,
            onChanged: _noopValue<int>,
            tabs: segments,
          ),
        ]),
        const SizedBox(height: 16),
        _wrap(const <Widget>[
          DsSpecimen(
            label: 'hover',
            state: DsPreviewStates.hover,
            child: AppTabs<int>(
              variant: AppTabsVariant.segmented,
              value: 0,
              onChanged: _noopValue<int>,
              tabs: segments,
            ),
          ),
          DsSpecimen(
            label: 'pressed',
            state: DsPreviewStates.pressed,
            child: AppTabs<int>(
              variant: AppTabsVariant.segmented,
              value: 0,
              onChanged: _noopValue<int>,
              tabs: segments,
            ),
          ),
          DsSpecimen(
            label: 'focused',
            state: DsPreviewStates.focused,
            width: 240,
            child: AppTabs<int>(value: 0, onChanged: _noopValue<int>, tabs: segments),
          ),
        ]),
      ],
    );
  }

  static Widget _navigation(BuildContext context) {
    final WindowClass wc = context.windowClass;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Шапка `full` по прототипу 2026-10-29 (ADR-112): «бургер» · логотип · поиск · корзина · колокольчик ·
        // пользователь; часов и даты нет.
        TopAppBarPos(
          windowClass: wc,
          variant: wc == WindowClass.compact ? TopAppBarVariant.compact : TopAppBarVariant.full,
          onMenu: _noop,
          menuLabel: 'Меню разделов',
          logo: const _LogoStub(),
          search: wc == WindowClass.compact ? null : const SearchBar(onScan: _noop, scannerLabel: 'Сканировать'),
          title: 'Каталог',
          actions: <Widget>[
            if (wc == WindowClass.compact)
              const AppIconButton(icon: Icons.barcode_reader, semanticLabel: 'Сканировать', onPressed: _noop)
            else
              const TopAppBarCartButton(
                label: 'Корзина',
                count: 3,
                totalText: '16 007,50 сом',
                semanticLabel: 'Открыть корзину, 3 позиции',
                onTap: _noop,
              ),
          ],
          bell: wc == WindowClass.compact
              ? const AppIconButton(
                  icon: Icons.notifications_outlined,
                  semanticLabel: 'Уведомления',
                  onPressed: _noop,
                  badge: AppBadge.dot(),
                )
              : const NotificationBell(unreadCount: 2, onPressed: _noop, semanticLabel: 'Уведомления, 2 непрочитанных'),
          user: wc == WindowClass.compact
              ? null
              : TopAppBarUser(name: 'Абдулла', role: 'Продавец', onTap: _noop, showText: wc != WindowClass.medium),
        ),
        const SizedBox(height: 16),
        const TopAppBarPos(variant: TopAppBarVariant.modal, title: 'Фильтры', onClose: _noop, closeLabel: 'Закрыть'),
        const SizedBox(height: 16),
        const BottomNavBar(destinations: dsShowcaseDestinations, selectedIndex: 2, onSelected: _noopValue<int>),
        const SizedBox(height: 16),
        // Кнопка-итог корзины (03 §9.70): с итогом, с предупреждением, без текста (узкое окно).
        const Wrap(
          spacing: 16,
          runSpacing: 16,
          children: <Widget>[
            TopAppBarCartButton(
              label: 'Корзина',
              count: 5,
              totalText: '16 007,50 сом',
              semanticLabel: 'Открыть корзину, 5 позиций',
              onTap: _noop,
            ),
            TopAppBarCartButton(
              label: 'Корзина',
              count: 12,
              totalText: '12 поз.',
              warning: true,
              semanticLabel: 'Открыть корзину, 12 позиций',
              onTap: _noop,
            ),
            TopAppBarCartButton(
              label: 'Корзина',
              count: 0,
              totalText: '0 поз.',
              showText: false,
              semanticLabel: 'Открыть корзину',
              onTap: _noop,
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Drawer навигации сотрудника (03 §9.71): вкладки режима + «Другие разделы», выбранный — тинт и полоса.
        const SizedBox(
          height: 520,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: NavigationDrawerApp(
              semanticLabel: 'Навигация',
              header: _LogoStub(),
              groups: <NavigationDrawerGroup>[
                NavigationDrawerGroup(
                  items: <NavigationDrawerItem>[
                    NavigationDrawerItem(
                      icon: Icons.category_outlined,
                      selectedIcon: Icons.category,
                      label: 'Каталог',
                      selected: true,
                      onTap: _noop,
                    ),
                    NavigationDrawerItem(icon: Icons.star_border_rounded, label: 'Избранное', onTap: _noop),
                    NavigationDrawerItem(icon: Icons.shopping_cart_outlined, label: 'Корзина', onTap: _noop),
                    NavigationDrawerItem(icon: Icons.group_outlined, label: 'Клиенты', onTap: _noop),
                    NavigationDrawerItem(icon: Icons.account_circle_outlined, label: 'Профиль', onTap: _noop),
                  ],
                ),
                NavigationDrawerGroup(
                  title: 'Другие разделы',
                  items: <NavigationDrawerItem>[
                    NavigationDrawerItem(icon: Icons.bookmark_border_rounded, label: 'Отложенные заказы', onTap: _noop),
                    NavigationDrawerItem(icon: Icons.receipt_outlined, label: 'Заказы', onTap: _noop),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(
              height: 460,
              child: NavigationRailApp(
                destinations: dsShowcaseDestinations,
                selectedIndex: 0,
                onSelected: _noopValue<int>,
                leading: _LogoStub(),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                children: <Widget>[
                  const AppSectionHeader(title: 'Недавние товары', actionLabel: 'Очистить', onAction: _noop),
                  const AppListTile(
                    title: 'Смесители',
                    leadingIcon: Icons.water_drop_outlined,
                    selected: true,
                    trailing: AppBadge(count: 24, tone: AppBadgeTone.cart),
                    onTap: _noop,
                  ),
                  const AppListTile(
                    title: 'Вход по биометрии',
                    subtitle: 'Отпечаток или лицо',
                    leadingIcon: Icons.fingerprint_rounded,
                    trailing: AppSwitch(value: true, onChanged: _noopValue<bool>),
                  ),
                  const AppDivider(),
                  const AppListTile(title: 'Выйти', leadingIcon: Icons.logout_rounded, showChevron: true, onTap: _noop),
                  if (wc != WindowClass.compact)
                    const SizedBox(
                      height: 200,
                      child: NavigationRailApp(
                        variant: NavigationRailVariant.extended,
                        destinations: dsShowcaseDestinations,
                        selectedIndex: 1,
                        onSelected: _noopValue<int>,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Каркас с навигацией, шапкой, сайдбаром и корзиной (golden трёх брейкпоинтов).
  static Widget scaffold(BuildContext context) {
    return AdaptiveScaffold(
      destinations: dsShowcaseDestinations,
      selectedIndex: 0,
      onDestinationSelected: _noopValue<int>,
      navigationLabel: 'Навигация',
      railLeading: const _LogoStub(),
      topBar: (BuildContext context, WindowClass wc) => TopAppBarPos(
        windowClass: wc,
        variant: wc == WindowClass.compact ? TopAppBarVariant.compact : TopAppBarVariant.full,
        // На medium логотип — в rail (03 §9.56), в шапке не дублируется.
        logo: wc == WindowClass.medium ? null : const _LogoStub(),
        onMenu: wc == WindowClass.compact ? null : _noop,
        menuLabel: 'Меню разделов',
        title: 'Каталог',
        search: wc == WindowClass.compact ? null : const SearchBar(onScan: _noop, scannerLabel: 'Сканировать'),
        actions: const <Widget>[
          AppIconButton(icon: Icons.notifications_outlined, semanticLabel: 'Уведомления', onPressed: _noop),
        ],
        user: wc.index >= WindowClass.expanded.index
            ? const TopAppBarUser(name: 'Абдулла', role: 'Продавец', onTap: _noop)
            : null,
      ),
      banner: const ErrorState.banner(
        message: 'Нет сети. Показаны данные от 09:41. Заказы недоступны',
        tone: ErrorStateTone.warning,
      ),
      sidebar: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const <Widget>[
          AppSectionHeader(title: 'Категории'),
          AppListTile(title: 'Смесители', leadingIcon: Icons.water_drop_outlined, selected: true, onTap: _noop),
          AppListTile(title: 'Инструменты', leadingIcon: Icons.handyman_outlined, onTap: _noop),
          AppListTile(title: 'Краски', leadingIcon: Icons.format_paint_outlined, onTap: _noop),
        ],
      ),
      cartPanel: const Padding(
        padding: EdgeInsets.all(20),
        child: EmptyState(variant: EmptyStateVariant.cart, title: 'Корзина пуста', body: 'Добавьте товары из каталога'),
      ),
      cartFab: const AppButton(
        label: '5 · 16 007,50 сом',
        icon: Icons.shopping_cart_rounded,
        onPressed: _noop,
        size: AppButtonSize.l,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Смесители', style: context.text.h2.copyWith(color: context.colors.textPrimary)),
            const SizedBox(height: 16),
            const Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                SizedBox(width: 160, child: SkeletonBox.image()),
                SizedBox(width: 160, child: SkeletonBox.image()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Заглушка логотипа до `SplashLogo` (RM-D-007; векторный логотип — O-22).
class _LogoStub extends StatelessWidget {
  const _LogoStub();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: context.colors.brandAccent, borderRadius: BorderRadius.all(context.radii.sm)),
        alignment: Alignment.center,
        child: Text('C', style: context.text.title.copyWith(color: context.colors.onBrandAccent)),
      ),
    );
  }
}
