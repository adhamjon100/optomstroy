// Журнал аудита SCR-47 (08 §4.18.7 `GET /admin/audit-logs`; D-36, 11 §7; RM-G-006, RM-G-012). Запись —
// `AuditRecord` (core/models/audit_record.dart; общая с SCR-37). Период обязателен и не длиннее 366 дней
// (`JournalPeriod`); `admin` — без финансовых before/after (фильтрует сервер), `owner` — полно. Экспорт CSV — R2.
// Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';

/// Фильтры журнала (02 §4.1 SCR-47: `from,to,userId,action,entityType,entityId,result`).
final class AuditQuery {
  const AuditQuery({
    required this.period,
    this.actorId,
    this.action,
    this.entityType,
    this.entityId,
    this.result,
    this.limit,
    this.cursor,
  });

  final JournalPeriod period;

  /// Сотрудник (`userId` маршрута → `actorId` API).
  final String? actorId;

  /// Префикс кода события (`payment.`), ≤ 100.
  final String? action;

  /// ≤ 64.
  final String? entityType;

  /// ≤ 64.
  final String? entityId;
  final AuditResult? result;
  final int? limit;
  final String? cursor;

  static const int actionMax = 100;
  static const int entityMax = 64;
}

abstract interface class AuditLogRepository {
  /// `GET /admin/audit-logs`; [cancel] — отмена устаревшего запроса при смене фильтров (SCR-47.11).
  Future<Result<PageResult<AuditRecord>>> list(AuditQuery query, {CancelSignal? cancel});
}
