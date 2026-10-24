// Подписи и справочники SCR-47 (02 SCR-47.3, SCR-47.8; 11 §7.2): название события — `audit_action_<action>`
// (точки → «_»), неизвестный код — `audit_action_unknown` с кодом (AC-UI-47-009); результат → `StatusChip`
// (`ok` success, `denied` error, `error` warning); префиксы групп действий UI-47-007 (фильтр `action` — префикс,
// ≤ 100); переход по объекту UI-47-011 (`order` → SCR-24, `customer` → SCR-32, `user` → SCR-45,
// `payment`/`transaction` → SCR-37, `return_request` → SCR-39, `sync_run` → SCR-43).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';

abstract final class AuditLabels {
  /// Префиксы групп действий (UI-47-007, 11 §7.2). Подписи групп в словаре 02 §7 отсутствуют (GQ-FEADM-02) —
  /// чип показывает сам префикс.
  static const List<String> actionPrefixes = <String>[
    'auth.',
    'session.',
    'user.',
    'invitation.',
    'discount.',
    'order.',
    'payment.',
    'credit.',
    'customer.',
    'receivables.',
    'return.',
    'sync.',
    'outbox.',
    'settings.',
    'report.',
    'audit.',
    'export.',
    'authz.',
  ];

  /// Название события: ключ формируется механически из кода (точки → «_», 02 SCR-47.8), неизвестный — код как есть.
  static String action(AppLocalizations l10n, String code) => switch (code.replaceAll('.', '_')) {
    'user_role_changed' => l10n.audit_action_user_role_changed,
    'discount_over_limit_approved' => l10n.audit_action_discount_over_limit_approved,
    'discount_limits_changed' => l10n.audit_action_discount_limits_changed,
    'payment_manual_qr_confirmed' => l10n.audit_action_payment_manual_qr_confirmed,
    'credit_sale_approved' => l10n.audit_action_credit_sale_approved,
    'order_cancel_requested' => l10n.audit_action_order_cancel_requested,
    'customer_finance_view' => l10n.audit_action_customer_finance_view,
    'sync_manual_started' => l10n.audit_action_sync_manual_started,
    'sync_prices_applied' => l10n.audit_action_sync_prices_applied,
    'sync_stock_applied' => l10n.audit_action_sync_stock_applied,
    'settings_changed' => l10n.audit_action_settings_changed,
    'user_blocked' => l10n.audit_action_user_blocked,
    'user_unblocked' => l10n.audit_action_user_unblocked,
    'auth_pin_reset' => l10n.audit_action_auth_pin_reset,
    _ => l10n.audit_action_unknown(code),
  };

  /// Подпись результата.
  static String result(AppLocalizations l10n, AuditResult? r) => switch (r) {
    AuditResult.ok => l10n.audit_result_ok,
    AuditResult.denied => l10n.audit_result_denied,
    AuditResult.error => l10n.audit_result_error,
    // Значение, неизвестное клиенту (08: `null`) — без подписи результата.
    null => '—',
  };

  /// Вариант чипа результата.
  static StatusChipVariant resultVariant(AuditResult? r) => switch (r) {
    AuditResult.ok => StatusChipVariant.success,
    AuditResult.denied => StatusChipVariant.error,
    AuditResult.error => StatusChipVariant.warning,
    null => StatusChipVariant.neutral,
  };

  /// Адрес объекта записи (UI-47-011) или `null`, если перехода нет.
  static String? objectLocation(String? entityType, String? entityId) {
    if (entityType == null || entityId == null || entityId.isEmpty) return null;
    final String id = Uri.encodeComponent(entityId);
    return switch (entityType) {
      'order' => '/orders/$id',
      'customer' => '/customers/$id',
      'user' => '/admin/users?userId=$id',
      'payment' || 'transaction' => '/transactions/$id',
      'return_request' => '/returns/$id',
      'sync_run' => '/sync?runId=$id',
      _ => null,
    };
  }

  /// Значение замаскировано сервером (SEC-083: `admin` не видит финансовые before/after). Форма маски в 08 не
  /// задана (GQ-FEADM-03): признаются `"***"`/`"•••"`, `{"masked": true}` и строки из `*`.
  static bool isMasked(Object? value) {
    if (value is Map && value['masked'] == true) return true;
    if (value is String) {
      final String v = value.trim();
      return v.isNotEmpty && RegExp(r'^[*•]+$').hasMatch(v);
    }
    return false;
  }
}
