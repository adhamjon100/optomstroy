// Матрица ролей в UI = матрица сервера (13 RM-G-008 п. 2, 11 §4.4, R0 §17.2 D-15; ревью G-flutter-ui-8, G-trace-6):
// тест читает contracts/rbac/permissions.yaml (источник seed сервера, RM-B-008) и для каждой роли сотрудника сверяет
// с правами видимость кассовых действий (CashierRoles — SCR-30/SCR-38), возможности экранов клиентов
// (CustomersViewer — SCR-31…SCR-35, SCR-40), заявок на возврат (ReturnsViewer — SCR-39), журнала SCR-43
// (SyncRunPolicy) и маршруты roleGuard.
// «⇔» — UI показывает действие ровно тем ролям, у которых есть право; «⇒» — UI показывает действие только ролям с
// правом (у роли может быть право, а действие на этом экране по ТЗ не показывается — например, admin на SCR-30).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/sync/sync_run_policy.dart';
import 'package:optomstroy/features/cashier/presentation/cashier_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';

/// Роли сотрудников (ядро §3.1; `customer` — режим клиента, `integration` — без UI).
const List<RoleCode> _staff = <RoleCode>[
  RoleCode.seller,
  RoleCode.cashier,
  RoleCode.seniorSeller,
  RoleCode.admin,
  RoleCode.owner,
];

/// `grants` из permissions.yaml: роль → коды прав (структура файла: `grants:` → `  role:` → `    - code`).
Map<String, Set<String>> _grants() {
  final File f = <File>[
    File('../contracts/rbac/permissions.yaml'),
    File('contracts/rbac/permissions.yaml'),
  ].firstWhere((File f) => f.existsSync(), orElse: () => throw StateError('permissions.yaml не найден'));
  final Map<String, Set<String>> out = <String, Set<String>>{};
  bool inGrants = false;
  String? role;
  for (final String raw in f.readAsLinesSync()) {
    final String line = raw.replaceFirst(RegExp(r'\s+#.*$'), '');
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) {
      inGrants = line.startsWith('grants:');
      role = null;
      continue;
    }
    if (!inGrants) continue;
    final RegExpMatch? r = RegExp(r'^  ([a-z_]+):\s*$').firstMatch(line);
    if (r != null) {
      role = r.group(1);
      out[role!] = <String>{};
      continue;
    }
    final RegExpMatch? p = RegExp(r'^    - ([a-z_.]+)\s*$').firstMatch(line);
    if (p != null && role != null) out[role]!.add(p.group(1)!);
  }
  return out;
}

void main() {
  final Map<String, Set<String>> grants = _grants();
  bool has(RoleCode r, String permission) => grants[r.value]?.contains(permission) ?? false;

  /// UI ⇔ право.
  void same(String what, bool Function(RoleCode r) ui, String permission) {
    for (final RoleCode r in _staff) {
      expect(ui(r), has(r, permission), reason: '$what для ${r.value} ⇔ $permission');
    }
  }

  /// UI ⇒ право.
  void implies(String what, bool Function(RoleCode r) ui, String permission) {
    for (final RoleCode r in _staff) {
      if (ui(r)) expect(has(r, permission), isTrue, reason: '$what у ${r.value} без права $permission');
    }
  }

  test('permissions.yaml прочитан: все роли сотрудников с правами', () {
    for (final RoleCode r in _staff) {
      expect(grants[r.value], isNotEmpty, reason: r.value);
    }
    expect(has(RoleCode.cashier, 'payment.cash.receive'), isTrue);
    expect(has(RoleCode.admin, 'payment.cash.receive'), isFalse); // D-15
  });

  test('SCR-30/SCR-38 — кассовые действия (CashierRoles)', () {
    same('«Принять оплату», SCR-38', CashierRoles.canAcceptPayment, 'payment.cash.receive');
    same('приём QR', CashierRoles.canAcceptPayment, 'payment.qr.confirm_manual');
    same('ручное подтверждение QR', CashierRoles.canConfirmManual, 'payment.qr.confirm_manual');
    same('аннулирование платежа', CashierRoles.canConfirmManual, 'payment.void');
    same('избранные клиенты SCR-30 Z3', CashierRoles.canManageFavorites, 'favorites.customers.manage');
    implies('«Новый клиент»', CashierRoles.canCreateCustomer, 'customer.create');
    implies('«Заявка на возврат»', CashierRoles.canStartReturn, 'return.create');
    implies('«Отложенные»', CashierRoles.canOpenParked, 'cart.manage.own');
    // Просмотр дашборда (admin, owner — режим просмотра) — только с `dashboard.cashier.read`.
    implies('режим просмотра SCR-30', CashierRoles.viewOnly, 'dashboard.cashier.read');
  });

  test('SCR-31…SCR-35, SCR-40 — возможности экранов клиентов (CustomersViewer)', () {
    CustomersViewer v(RoleCode r) => CustomersViewer(role: r);
    same('суммы долга', (RoleCode r) => v(r).seesSums, 'customer.receivables.read.summary');
    same('SCR-33 история', (RoleCode r) => v(r).canReadHistory, 'customer.history.read');
    same('SCR-34 долги', (RoleCode r) => v(r).canReadReceivables, 'customer.receivables.read.summary');
    implies('«Обновить» снимок долга', (RoleCode r) => v(r).canRefreshReceivables, 'customer.receivables.read.summary');
    same('избранные клиенты', (RoleCode r) => v(r).canManageFavorites, 'favorites.customers.manage');
    same('фильтр «С долгом»', (RoleCode r) => v(r).canFilterDebt, 'customer.receivables.read.summary');
    same('SCR-26 «Новый клиент»', (RoleCode r) => v(r).canCreateCustomer, 'customer.create');
    same('оплата долга без заказа', (RoleCode r) => v(r).canAcceptDebtPayment, 'payment.debt.receive');
    implies('«В заказ»', (RoleCode r) => v(r).canAddToCart, 'cart.manage.own');
    same('привязки клиента', (RoleCode r) => v(r).canReadLinks, 'customer.link.read');
    same('разрешение конфликтов привязок', (RoleCode r) => v(r).canResolveLinks, 'customer.link.resolve');
  });

  test('SCR-39 — заявки на возврат (ReturnsViewer)', () {
    same('создание заявки', (RoleCode r) => ReturnsViewer(role: r).canCreate, 'return.create');
    same('согласование заявки', (RoleCode r) => ReturnsViewer(role: r).canApprove, 'return.approve');
  });

  test('SCR-43 — журнал и очередь «в 1С» (SyncRunPolicy)', () {
    same('журнал прогонов и ошибок', SyncRunPolicy.canViewJournal, 'sync.runs.read');
    same('вкладка «Outbox» и «Повторить»', SyncRunPolicy.canManageOutbox, 'sync.outbox.manage');
    implies('«Запустить…»', SyncRunPolicy.canOpenRunDialog, 'sync.run.full');
  });

  test('roleGuard — маршруты по правам (navigation.md G-7, 11 §4.4)', () {
    bool path(RoleCode r, String p) => isPathAllowedForRole(r, p);
    same('/payments/new (SCR-38)', (RoleCode r) => path(r, '/payments/new'), 'payment.cash.receive');
    same('/customers/{id}/history (SCR-33)', (RoleCode r) => path(r, '/customers/c1/history'), 'customer.history.read');
    same(
      '/customers/{id}/receivables (SCR-34)',
      (RoleCode r) => path(r, '/customers/c1/receivables'),
      'customer.receivables.read.detail',
    );
    same('/customers/new (SCR-26)', (RoleCode r) => path(r, '/customers/new'), 'customer.create');
    same('/returns/new (SCR-39)', (RoleCode r) => path(r, '/returns/new'), 'return.create');
    same('/returns/{id} (SCR-39)', (RoleCode r) => path(r, '/returns/r1'), 'return.read');
    same('/cashier (SCR-30)', (RoleCode r) => path(r, '/cashier'), 'dashboard.cashier.read');
    same('/cart (SCR-20)', (RoleCode r) => path(r, '/cart'), 'cart.manage.own');
    same('/checkout (SCR-21)', (RoleCode r) => path(r, '/checkout'), 'order.create');
    implies('/admin/audit (SCR-47)', (RoleCode r) => path(r, '/admin/audit'), 'audit.read');
    implies('/admin/settings (SCR-46)', (RoleCode r) => path(r, '/admin/settings'), 'settings.app.read');
    implies('/reports (SCR-48)', (RoleCode r) => path(r, '/reports'), 'reports.sales.read');
    for (final RoleCode r in _staff) {
      if (path(r, '/transactions')) {
        expect(
          has(r, 'transactions.read.own') || has(r, 'transactions.read.all'),
          isTrue,
          reason: '/transactions (SCR-36) у ${r.value} без transactions.read.*',
        );
      }
    }
  });
}
