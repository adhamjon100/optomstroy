// Порт заявок на возврат (SCR-39; 08 §4.15; 10 RET-, ядро §22.11, §23 п. 8). Только онлайн (02 `return_offline_*`).
// Переходы: `draft → submitted` (`submit`, step-up; сверх порога — держатель `return.approve`), `submitted → accepted`
// (`accept`, только при `RETURNS_FROM_POS_ENABLED=false`, `return.approve` + step-up), `submitted|accepted → rejected`
// (`reject`, `return.approve` + step-up), удаление — только черновик. Все изменения — с `rowVersion`.
// `stepUpToken` — явный токен (иначе AuthInterceptor берёт его из кэша/StepUpDialog). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';

abstract interface class ReturnsRepository {
  /// `GET /returns`.
  Future<Result<PageResult<ReturnRequest>>> list(ReturnsQuery query);

  /// `GET /returns/{id}`.
  Future<Result<ReturnRequest>> get(String returnId);

  /// `POST /returns` (черновик; `Idempotency-Key` обязателен).
  Future<Result<ReturnRequest>> create(ReturnDraftInput input, {required String idempotencyKey});

  /// `PATCH /returns/{id}`.
  Future<Result<ReturnRequest>> update(String returnId, ReturnDraftPatch patch, {String? idempotencyKey});

  /// `DELETE /returns/{id}?rowVersion=` — только черновик.
  Future<Result<void>> delete(String returnId, {required int rowVersion});

  /// `POST /returns/{id}/submit`.
  Future<Result<ReturnRequest>> submit(
    String returnId, {
    required int rowVersion,
    required String idempotencyKey,
    String? comment,
    String? stepUpToken,
  });

  /// `POST /returns/{id}/accept` (только при `RETURNS_FROM_POS_ENABLED=false`).
  Future<Result<ReturnRequest>> accept(
    String returnId, {
    required int rowVersion,
    required String idempotencyKey,
    String? comment,
    String? stepUpToken,
  });

  /// `POST /returns/{id}/reject`.
  Future<Result<ReturnRequest>> reject(
    String returnId, {
    required String reason,
    required int rowVersion,
    required String idempotencyKey,
    String? stepUpToken,
  });
}
