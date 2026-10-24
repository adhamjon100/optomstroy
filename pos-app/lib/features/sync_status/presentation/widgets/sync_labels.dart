// Подписи SCR-43 из ARB (02 §7 ч. E; 03 §16): сущности `sync_entity_*`, режимы `sync_mode_*`, статусы прогонов
// `status_sync_*` (03 §9.39, §16.7; EQ-E009-04).
import 'package:flutter/widgets.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';

abstract final class SyncLabels {
  static String entity(AppLocalizations l10n, SyncEntity e) => switch (e) {
    SyncEntity.categories => l10n.sync_entity_categories,
    SyncEntity.products => l10n.sync_entity_products,
    SyncEntity.variants => l10n.sync_entity_variants,
    SyncEntity.attributes => l10n.sync_entity_attributes,
    SyncEntity.units => l10n.sync_entity_units,
    SyncEntity.barcodes => l10n.sync_entity_barcodes,
    SyncEntity.images => l10n.sync_entity_images,
    SyncEntity.warehouses => l10n.sync_entity_warehouses,
    SyncEntity.stock => l10n.sync_entity_stock,
    SyncEntity.prices => l10n.sync_entity_prices,
    SyncEntity.customers => l10n.sync_entity_customers,
    SyncEntity.receivables => l10n.sync_entity_receivables,
    SyncEntity.salesHistory => l10n.sync_entity_sales_history,
    SyncEntity.orderStatus => l10n.sync_entity_order_status,
    SyncEntity.discounts => l10n.sync_entity_discounts,
    SyncEntity.paymentDocs => l10n.sync_entity_payment_docs,
    SyncEntity.returnDocs => l10n.sync_entity_return_docs,
  };

  /// Подпись по строке сущности (неизвестное значение — как есть).
  static String entityValue(AppLocalizations l10n, String value) {
    final e = SyncEntity.tryParse(value);
    return e == null ? value : entity(l10n, e);
  }

  static String mode(AppLocalizations l10n, SyncMode m) => switch (m) {
    SyncMode.incremental || SyncMode.manual => l10n.sync_mode_incremental,
    SyncMode.full => l10n.sync_mode_full,
    SyncMode.reconcile => l10n.sync_mode_reconcile,
  };

  static String quickButton(AppLocalizations l10n, SyncEntity e) => switch (e) {
    SyncEntity.stock => l10n.sync_run_button_stock,
    SyncEntity.prices => l10n.sync_run_button_prices,
    SyncEntity.orderStatus => l10n.sync_run_button_order_status,
    _ => entity(l10n, e),
  };

  static String trigger(AppLocalizations l10n, SyncRunInfo run) => switch (run.trigger) {
    SyncTrigger.schedule => l10n.sync_trigger_schedule,
    SyncTrigger.manual => l10n.sync_trigger_manual(run.triggeredByName ?? ''),
    SyncTrigger.retry => l10n.sync_trigger_retry,
    SyncTrigger.dependency => l10n.sync_trigger_dependency,
    null => l10n.sync_trigger_auto,
  };

  /// Чип статуса прогона (03 §9.39: `sync.*`).
  static (String, StatusChipVariant) runStatus(AppLocalizations l10n, SyncRunInfo run) => switch (run.status) {
    SyncRunStatus.success => (l10n.status_sync_success, StatusChipVariant.success),
    SyncRunStatus.partial => (l10n.status_sync_partial, StatusChipVariant.warning),
    SyncRunStatus.failed => (l10n.status_sync_failed, StatusChipVariant.error),
    SyncRunStatus.running => (l10n.status_sync_running, StatusChipVariant.info),
    SyncRunStatus.queued || null => (l10n.status_sync_queued, StatusChipVariant.neutral),
  };

  static (String, StatusChipVariant) overall(AppLocalizations l10n, String overall) => switch (overall) {
    'ok' => (l10n.sync_overall_ok, StatusChipVariant.success),
    'failed' => (l10n.sync_overall_failed, StatusChipVariant.error),
    _ => (l10n.sync_overall_degraded, StatusChipVariant.warning),
  };

  /// Сущности кэша устройства с подписью `sync_entity_*` (виды цен и упаковки своей подписи не имеют).
  static SyncEntity? cacheEntity(String value) => switch (value) {
    'price_lists' || 'packagings' => null,
    _ => SyncEntity.tryParse(value),
  };

  static AppLocalizations of(BuildContext context) => AppLocalizations.of(context);
}
