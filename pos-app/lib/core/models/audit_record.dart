// Запись журнала аудита (08 §4.18 `AuditRow`; D-36, 11 §7) — общая сущность этапа G для фич admin (SCR-47) и
// transactions (SCR-37 «Журнал изменений», только admin/owner). Лежит в core/models: admin и transactions не связаны
// в DAG 06 §6.1. Чистый Dart (FL-01). `before`/`after` — как пришли (для `admin` сервер присылает их без финансовых
// полей, ядро §17.2); в лог и на диск не пишутся.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';

final class AuditRecord {
  const AuditRecord({
    required this.id,
    required this.occurredAt,
    required this.action,
    required this.result,
    required this.chainOk,
    this.requestId,
    this.actor,
    this.actorRole,
    this.sessionId,
    this.deviceId,
    this.ip,
    this.appVersion,
    this.entityType,
    this.entityId,
    this.onecRef,
    this.before,
    this.after,
    this.stepUpMethod,
    this.reason,
    this.rowHash,
  });

  final String id;
  final DateTime occurredAt;

  /// Код события (`payment.void`, `discount.override`, … — 11 §7.2).
  final String action;

  /// `null` — значение, неизвестное клиенту.
  final AuditResult? result;

  /// Признак целостности хэш-цепочки относительно последнего якоря (RM-G-011, R0 §19.2).
  final bool chainOk;
  final String? requestId;
  final UserRef? actor;
  final RoleCode? actorRole;
  final String? sessionId;
  final String? deviceId;
  final String? ip;
  final String? appVersion;
  final String? entityType;
  final String? entityId;
  final String? onecRef;
  final Map<String, Object?>? before;
  final Map<String, Object?>? after;
  final StepUpMethod? stepUpMethod;
  final String? reason;
  final String? rowHash;

  @override
  String toString() => 'AuditRecord($id, $action)';
}
