// SCR-32 «Карточка клиента» (02 SCR-32; RM-G-007): шапка с «Назад», заголовок — имя клиента, «Обновить»; тело —
// [CustomerCardView] (поля и действия по роли, вкладки; expanded — содержимое вкладок внутри, `?tab=`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_card_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_card_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_self_gate.dart';

/// SCR-32. Карточка клиента `/customers/{id}?tab=` (staff — поля по роли; `customer` — своя при `confirmed`,
/// иначе — статус привязки без запроса карточки).
class CustomerCardScreen extends ConsumerWidget {
  /// Экран SCR-32.
  const CustomerCardScreen({required this.customerId, this.tab, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-32';

  /// ID клиента.
  final String customerId;

  /// Вкладка на expanded (`history|receivables|discounts|orders`).
  final String? tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CustomerAccess access = ref.watch(
      customersViewerProvider.select((CustomersViewer v) => v.accessTo(customerId)),
    );
    // Режим клиента: до подтверждённой привязки и для чужой карточки — без запроса карточки (10 CUST-025).
    if (access != CustomerAccess.staff && access != CustomerAccess.own) {
      return Scaffold(
        key: const ValueKey<String>('stub-SCR-32'),
        appBar: AppBar(title: Text(AppLocalizations.of(context).profile_customer_link_title)),
        body: CustomerSelfGate(customerId: customerId, builder: (BuildContext context) => const SizedBox.shrink()),
      );
    }
    return _CustomerCard(customerId: customerId, tab: tab);
  }
}

class _CustomerCard extends ConsumerWidget {
  const _CustomerCard({required this.customerId, this.tab});

  final String customerId;
  final String? tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomerCardState s = ref.watch(customerCardProvider(customerId));
    final CustomerCardController ctl = ref.read(customerCardProvider(customerId).notifier);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(ctl.refresh()),
      },
      child: Scaffold(
        key: const ValueKey<String>('stub-SCR-32'),
        appBar: AppBar(
          title: Text(s.customer?.title ?? l10n.customers_search_title),
          actions: <Widget>[
            if (s.phase == CustomerCardPhase.ready)
              AppIconButton(
                key: const ValueKey<String>('customer-card-refresh'),
                icon: Icons.refresh_rounded,
                semanticLabel: l10n.receivables_refresh,
                onPressed: s.refreshing ? null : () => unawaited(ctl.refresh()),
              ),
          ],
        ),
        body: CustomerSelfGate(
          customerId: customerId,
          builder: (BuildContext context) => CustomerCardView(customerId: customerId, tab: tab),
        ),
      ),
    );
  }
}
