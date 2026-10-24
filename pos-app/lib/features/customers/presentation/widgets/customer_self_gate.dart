// Режим клиента на экранах SCR-32…SCR-35 (RM-G-014; 10 CUST-025, ядро §22.12, 11 SEC-030; 02 SCR-32…SCR-35,
// AC-UI-41-010): `customer` видит только свою карточку 1С и только при подтверждённой привязке. До подтверждения
// (`none`/`proposed`/`conflict`/`rejected`) запросов долга, истории и скидок нет — показан статус привязки; чужой
// `customerId` — «Клиент не найден» без запроса (сервер ответил бы `404`); при `CUSTOMER_SELF_SERVICE=false` — «Раздел
// недоступен» без запросов (10 CASH-006). Сотрудникам гейт ничего не меняет.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';

/// Ключи (тесты).
abstract final class CustomerSelfGateKeys {
  static const Key loading = ValueKey<String>('customer-self-loading');
  static const Key notLinked = ValueKey<String>('customer-self-not-linked');
  static const Key linkStatus = ValueKey<String>('customer-self-link-status');
  static const Key confirmLink = ValueKey<String>('customer-self-confirm-link');
  static const Key foreign = ValueKey<String>('customer-self-foreign');
}

/// Пути режима клиента (строками маршрутов `app/router/routes.dart`; фича не импортирует app/).
abstract final class CustomerSelfPaths {
  /// SCR-06 «Привязка к карточке 1С» (`proposed`).
  static const String customerLink = '/register/customer-link';

  /// SCR-41 «Профиль» (корень ветки клиента, где показан статус привязки).
  static const String profile = '/profile';
}

/// Гейт экранов клиента: сотрудник и `customer` со своей подтверждённой карточкой видят [builder], прочие `customer` —
/// состояние привязки или «не найден».
class CustomerSelfGate extends ConsumerStatefulWidget {
  /// Создаёт гейт.
  const CustomerSelfGate({required this.customerId, required this.builder, super.key});

  /// Клиент экрана.
  final String customerId;

  /// Содержимое экрана (строится только при доступе).
  final WidgetBuilder builder;

  @override
  ConsumerState<CustomerSelfGate> createState() => _CustomerSelfGateState();
}

class _CustomerSelfGateState extends ConsumerState<CustomerSelfGate> {
  @override
  void initState() {
    super.initState();
    // Статус привязки мог измениться (SCR-06, решение администратора) — перечитать `GET /me` при входе на экран;
    // прежнее значение остаётся на время запроса (без мерцания).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(customersViewerProvider).isCustomer) ref.invalidate(customerSelfLinkProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    return switch (viewer.accessTo(widget.customerId)) {
      CustomerAccess.staff || CustomerAccess.own => widget.builder(context),
      CustomerAccess.loading => const Center(key: CustomerSelfGateKeys.loading, child: CircularProgressIndicator()),
      CustomerAccess.notLinked => CustomerLinkRequired(status: viewer.selfLink?.status),
      CustomerAccess.foreign => _foreign(context),
      CustomerAccess.disabled => CustomerStates.forbidden(context),
    };
  }

  Widget _foreign(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ErrorState.fullScreen(
      key: CustomerSelfGateKeys.foreign,
      title: l10n.customer_card_not_found,
      message: l10n.error_not_found,
      onBack: () => GoRouter.maybeOf(context)?.go(CustomerSelfPaths.profile),
      backLabel: l10n.profile_title,
    );
  }
}

/// «Финансовые данные не показываются до подтверждения» + статус привязки (02 UI-41-011, UI-50-014; 09 §7.9):
/// `proposed` — «Проверить» → SCR-06; `conflict` — «Ожидает подтверждения администратором»; `rejected` — заказы
/// оформляются как новый клиент.
class CustomerLinkRequired extends StatelessWidget {
  /// Создаёт состояние.
  const CustomerLinkRequired({this.status, super.key});

  /// Статус привязки; `null` — привязки нет.
  final CustomerLinkStatus? status;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomerLinkStatus? s = status;
    final String? note = switch (s) {
      CustomerLinkStatus.conflict => l10n.link_wait_admin,
      CustomerLinkStatus.rejected => l10n.home_link_rejected,
      _ => null,
    };
    return Center(
      key: CustomerSelfGateKeys.notLinked,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(context.space.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            EmptyState(
              variant: EmptyStateVariant.noPermission,
              title: l10n.home_my_debt_unavailable,
              body: l10n.link_finance_hidden,
            ),
            if (s != null) ...<Widget>[
              SizedBox(height: context.space.s3),
              StatusChip(
                key: CustomerSelfGateKeys.linkStatus,
                label: CustomersTexts.linkStatus(l10n, s),
                variant: StatusChipMapping.variantOf('link', s.value) ?? StatusChipVariant.neutral,
              ),
            ],
            if (note != null) ...<Widget>[
              SizedBox(height: context.space.s2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  note,
                  textAlign: TextAlign.center,
                  style: context.text.body.copyWith(color: context.colors.textSecondary),
                ),
              ),
            ],
            if (s == CustomerLinkStatus.proposed) ...<Widget>[
              SizedBox(height: context.space.s3),
              AppButton(
                key: CustomerSelfGateKeys.confirmLink,
                label: l10n.home_link_proposed_action,
                variant: AppButtonVariant.outlined,
                onPressed: () => unawaited(GoRouter.maybeOf(context)?.push<void>(CustomerSelfPaths.customerLink)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
