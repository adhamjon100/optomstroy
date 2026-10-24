// Правило ручного запуска синхронизации (ядро R0 §17.2; 08 §4.17.2; 11 §4.3–§4.4; 02 SCR-43.10;
// contracts/rbac/permissions.yaml: `sync.run.incremental.limited`, `sync.run.full` — step-up `sync_admin`).
//
// - `senior_seller` — только `incremental` для `stock`/`prices`/`order_status`, без step-up;
// - `admin`, `owner` — любой запуск; всё, кроме трёх `incremental`, — со step-up (`sync.run.full`);
// - `seller`, `cashier` — запуск недоступен (подсказка `sync_permission_hint`).
// Скрытие кнопок — не защита: сервер всё равно проверяет права (SEC-028).
import 'package:optomstroy/core/enums.dart';

abstract final class SyncRunPolicy {
  /// Сущности быстрого `incremental` (кнопки «Обновить остатки/цены/статусы»).
  static const List<SyncEntity> quickEntities = <SyncEntity>[
    SyncEntity.stock,
    SyncEntity.prices,
    SyncEntity.orderStatus,
  ];

  /// Операция step-up для `POST /auth/step-up` (08 §4.17.2, 02 SCR-43.4).
  static const String stepUpOperation = 'sync.run.full';

  /// Режимы диалога «Запустить…» (UI-43-012).
  static const List<SyncMode> dialogModes = <SyncMode>[SyncMode.incremental, SyncMode.full, SyncMode.reconcile];

  /// Порядок сущностей на SCR-43 (зона B, «в порядке важности»).
  static const List<SyncEntity> displayOrder = <SyncEntity>[
    SyncEntity.stock,
    SyncEntity.prices,
    SyncEntity.orderStatus,
    SyncEntity.products,
    SyncEntity.variants,
    SyncEntity.categories,
    SyncEntity.barcodes,
    SyncEntity.units,
    SyncEntity.warehouses,
    SyncEntity.customers,
    SyncEntity.receivables,
    SyncEntity.discounts,
    SyncEntity.salesHistory,
    SyncEntity.paymentDocs,
    SyncEntity.returnDocs,
    SyncEntity.attributes,
    SyncEntity.images,
  ];

  static bool _isManager(RoleCode? role) => role == RoleCode.admin || role == RoleCode.owner;

  /// Журнал прогонов, счётчики, ошибки (`sync.runs.read`).
  static bool canViewJournal(RoleCode? role) => role == RoleCode.seniorSeller || _isManager(role);

  /// Счётчики очереди 1С в зоне A (UI-43-020: `admin`, `senior_seller`; `owner` — только числа).
  static bool seesOutboxCounts(RoleCode? role) => canViewJournal(role);

  /// Вкладка «Outbox» (`sync.outbox.manage`).
  static bool canManageOutbox(RoleCode? role) => role == RoleCode.admin || role == RoleCode.seniorSeller;

  /// Диалог «Запустить…» (UI-43-005/012).
  static bool canOpenRunDialog(RoleCode? role) => _isManager(role);

  /// Кнопки быстрого `incremental` (UI-43-004) — у `senior_seller`.
  static List<SyncEntity> quickButtonsFor(RoleCode? role) =>
      role == RoleCode.seniorSeller ? quickEntities : const <SyncEntity>[];

  /// Есть ли у роли ручной запуск вообще (иначе — подсказка UI-43-003).
  static bool canStartAny(RoleCode? role) => role == RoleCode.seniorSeller || _isManager(role);

  /// Запуск быстрого `incremental` (без step-up).
  static bool isQuick(SyncEntity entity, SyncMode mode) =>
      mode == SyncMode.incremental && quickEntities.contains(entity);

  /// Роль может запустить [entity] в режиме [mode].
  static bool canStart(RoleCode? role, SyncEntity entity, SyncMode mode) {
    if (!dialogModes.contains(mode)) return false;
    if (_isManager(role)) return true;
    if (role == RoleCode.seniorSeller) return isQuick(entity, mode);
    return false;
  }

  /// Нужен step-up `sync.run.full`: всё, кроме `incremental` для трёх сущностей.
  static bool requiresStepUp(SyncEntity entity, SyncMode mode) => !isQuick(entity, mode);
}
