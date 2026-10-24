// SCR-34 «Долги и взаиморасчёты» (02 SCR-34; RM-G-007, RM-G-012): заголовок + имя клиента из памяти сессии; тело —
// [ReceivablesView] (сводка без step-up; детализация — step-up при первом просмотре и через 15 мин; «Обновить»).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_receivables_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_screen_title.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_self_gate.dart';
import 'package:optomstroy/features/customers/presentation/widgets/debt_refresh_feedback.dart';
import 'package:optomstroy/features/customers/presentation/widgets/receivables_view.dart';

/// SCR-34. Долги и взаиморасчёты `/customers/{id}/receivables` (детализация — step-up при первом просмотре и через 15 мин).
class CustomerReceivablesScreen extends ConsumerWidget {
  /// Экран SCR-34.
  const CustomerReceivablesScreen({required this.customerId, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-34';

  /// ID клиента.
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    Future<void> refresh() async {
      if (!viewer.canReadReceivables) return;
      final outcome = await ref.read(customerReceivablesProvider(customerId).notifier).refresh();
      if (context.mounted) showDebtRefreshOutcome(context, outcome, ref.read(clockProvider).nowUtc());
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(refresh()),
      },
      child: Scaffold(
        key: const ValueKey<String>('stub-SCR-34'),
        appBar: AppBar(
          title: CustomerScreenTitle(
            title: AppLocalizations.of(context).receivables_title,
            subtitle: ref.watch(customerNamesProvider).nameOf(customerId),
          ),
        ),
        body: CustomerSelfGate(
          customerId: customerId,
          builder: (BuildContext context) => ReceivablesView(customerId: customerId),
        ),
      ),
    );
  }
}
