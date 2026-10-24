// Заявка на возврат (08 §4.15 `ReturnRequest`, `ReturnRequestItem`, тела `ReturnsCreate|Update|Submit|Accept|Reject`;
// 10 RET-, ядро §22.11, §23 п. 8; D-25 — документ возврата и деньги оформляются в 1С). SCR-39, R1 must; модуль
// отключается только `returns_enabled=false` (`features.returnsFromPos`, 10 RET-012). Суммы клиент не передаёт —
// сумму возврата считает сервер. Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Строка заявки (`ReturnRequestItem`).
final class ReturnRequestItem {
  const ReturnRequestItem({
    required this.orderLineNo,
    required this.variantId,
    required this.quantity,
    this.maxReturnable,
    this.amount,
  });

  final int orderLineNo;
  final String variantId;
  final LineQuantity quantity;

  /// Можно вернуть (отгружено − возвращено); `null` — нет данных о прежних возвратах (02 `return_no_previous_data`).
  final Qty? maxReturnable;

  /// Предварительная сумма строки (считает сервер).
  final Money? amount;
}

/// Заявка на возврат (`ReturnRequest`).
final class ReturnRequest {
  const ReturnRequest({
    required this.id,
    required this.status,
    required this.orderId,
    required this.items,
    required this.rowVersion,
    this.publicNumber,
    this.shipmentRef,
    this.shipmentNumber,
    this.customerId,
    this.reasonCode,
    this.reasonComment,
    this.totalAmount,
    this.refundKind,
    this.approvalReason,
    this.onecRef,
    this.onecStatus,
    this.createdBy,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? publicNumber;

  /// `null` — статус, неизвестный клиенту (совместимость вперёд): действия не показываются.
  final ReturnRequestStatus? status;
  final String orderId;
  final String? shipmentRef;
  final String? shipmentNumber;
  final String? customerId;
  final ReturnReason? reasonCode;
  final String? reasonComment;
  final List<ReturnRequestItem> items;
  final Money? totalAmount;
  final PaymentMethod? refundKind;

  /// `return_threshold_exceeded` — сумма выше `return_approval_threshold`: отправляет держатель `return.approve`.
  final ReturnApprovalReason? approvalReason;
  final String? onecRef;
  final String? onecStatus;

  /// Версия строки для `PATCH`/`submit`/`accept`/`reject`/`DELETE` (`VERSION_CONFLICT` при расхождении).
  final int rowVersion;

  /// Автор черновика (`audit.createdBy`) — «Черновик сотрудника {name}» (02 `return_foreign_draft`).
  final UserRef? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isDraft => status == ReturnRequestStatus.draft;

  @override
  String toString() => 'ReturnRequest($id, ${status?.value})';
}

/// Позиция ввода (`ReturnsItemInput`).
final class ReturnItemInput {
  const ReturnItemInput({required this.orderLineNo, required this.quantity});

  final int orderLineNo;
  final LineQuantity quantity;
}

/// Новый черновик (`ReturnsCreateRequest`, `POST /returns`).
final class ReturnDraftInput {
  const ReturnDraftInput({
    required this.orderId,
    required this.reasonCode,
    required this.items,
    this.reasonComment,
    this.refundKind,
  });

  final String orderId;
  final ReturnReason reasonCode;

  /// Обязателен при `other` (≤ 500).
  final String? reasonComment;

  /// 1…200 позиций.
  final List<ReturnItemInput> items;
  final PaymentMethod? refundKind;
}

/// Правка черновика (`ReturnsUpdateRequest`, `PATCH /returns/{id}`): `null` — поле не меняется.
final class ReturnDraftPatch {
  const ReturnDraftPatch({
    required this.rowVersion,
    this.reasonCode,
    this.reasonComment,
    this.items,
    this.refundKind,
    this.clearRefundKind = false,
  });

  final int rowVersion;
  final ReturnReason? reasonCode;
  final String? reasonComment;
  final List<ReturnItemInput>? items;
  final PaymentMethod? refundKind;

  /// Явно передать `refundKind: null`.
  final bool clearRefundKind;
}

/// Фильтры `GET /returns`.
final class ReturnsQuery {
  const ReturnsQuery({this.status, this.orderId, this.customerId, this.from, this.to, this.limit, this.cursor});

  final ReturnRequestStatus? status;
  final String? orderId;
  final String? customerId;
  final DateTime? from;
  final DateTime? to;
  final int? limit;
  final String? cursor;
}

/// Ограничения тел запросов (OpenAPI 1.2.0).
abstract final class ReturnLimits {
  static const int reasonCommentMax = 500;
  static const int submitCommentMax = 200;
  static const int acceptCommentMax = 500;
  static const int rejectReasonMax = 500;
  static const int itemsMax = 200;
}
