// SCR-33 «История покупок клиента» (02 SCR-33; RM-G-007): заголовок «История покупок» + имя клиента из памяти сессии;
// тело — [CustomerHistoryView] (cashier, senior_seller, admin, owner; `seller` — «Нет доступа к разделу»).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_history_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_history_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_screen_title.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_self_gate.dart';

/// SCR-33. История покупок `/customers/{id}/history?from=&to=&source=` (cashier, senior_seller, admin, owner; `customer` — свой при `confirmed`).
class CustomerHistoryScreen extends ConsumerWidget {
  /// Экран SCR-33.
  const CustomerHistoryScreen({required this.customerId, this.from, this.to, this.source, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-33';

  /// ID клиента.
  final String customerId;

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601).
  final String? to;

  /// `pos|onec|all`.
  final String? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    key: const ValueKey<String>('stub-SCR-33'),
    appBar: AppBar(
      title: CustomerScreenTitle(
        title: AppLocalizations.of(context).customer_history_title,
        subtitle: ref.watch(customerNamesProvider).nameOf(customerId),
      ),
    ),
    body: CustomerSelfGate(
      customerId: customerId,
      builder: (BuildContext context) => CustomerHistoryView(
        args: CustomerHistoryArgs(customerId, from: from, to: to, source: source),
      ),
    ),
  );
}
