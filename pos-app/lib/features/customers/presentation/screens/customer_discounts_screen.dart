// SCR-35 «Скидки и условия» (02 SCR-35; RM-G-007): заголовок + имя клиента из памяти сессии; тело —
// [CustomerDiscountsView] (только чтение; F5 — повторная загрузка обоих запросов одним набором).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_discounts_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_discounts_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_screen_title.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_self_gate.dart';

/// SCR-35. Скидки и условия `/customers/{id}/discounts` (seller+, только чтение; `customer` — свои при `confirmed`).
class CustomerDiscountsScreen extends ConsumerWidget {
  /// Экран SCR-35.
  const CustomerDiscountsScreen({required this.customerId, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-35';

  /// ID клиента.
  final String customerId;

  bool _allowed(WidgetRef ref) {
    final CustomerAccess a = ref.read(customersViewerProvider).accessTo(customerId);
    return a == CustomerAccess.staff || a == CustomerAccess.own;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.f5): () {
        if (!_allowed(ref)) return;
        unawaited(ref.read(customerDiscountsProvider(customerId).notifier).load());
      },
    },
    child: Scaffold(
      key: const ValueKey<String>('stub-SCR-35'),
      appBar: AppBar(
        title: CustomerScreenTitle(
          title: AppLocalizations.of(context).customer_discounts_title,
          subtitle: ref.watch(customerNamesProvider).nameOf(customerId),
        ),
      ),
      body: CustomerSelfGate(
        customerId: customerId,
        builder: (BuildContext context) => CustomerDiscountsView(customerId: customerId),
      ),
    ),
  );
}
