// DTO-кодеки уведомлений (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `Notification`,
// `NotificationsUnreadCount`, ответ `GET /notifications` (`Page<Notification>` + `unreadCount`).
// Сверка — test/features/notifications/data/notification_dtos_contract_test.dart.
import 'dart:convert';

import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/notifications_cache_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';

/// `Notification`.
abstract final class NotificationDto {
  static const Set<String> jsonKeys = {'id', 'kind', 'title', 'body', 'payload', 'createdAt', 'readAt', 'severity'};
  static const Set<String> requiredKeys = {'id', 'kind', 'title', 'createdAt', 'severity'};

  /// Явные свойства `payload` (остальные — `additionalProperties: true`; OpenAPI 1.2.0, 08 §3.13).
  static const Set<String> payloadKeys = {
    'orderId',
    'target',
    'paymentId',
    'status',
    'cartId',
    'entity',
    'runId',
    'task',
    'outboxId',
  };

  static AppNotification fromJson(JsonMap j) {
    final JsonMap payload = jObject(j, 'payload') ?? const <String, dynamic>{};
    return _build(
      payload: Map<String, Object?>.unmodifiable(payload),
      id: jReq<String>(j, 'id'),
      rawKind: jReq<String>(j, 'kind'),
      title: jReq<String>(j, 'title'),
      body: jOpt<String>(j, 'body'),
      createdAt: jReqDate(j, 'createdAt'),
      readAt: jDate(j, 'readAt'),
      severity: jEnum(j, 'severity', NotificationSeverity.tryParse) ?? NotificationSeverity.info,
    );
  }

  /// Уведомление с разбором явных ключей `payload` (строки; значение другого типа — `null`, 08 §2.11).
  static AppNotification _build({
    required Map<String, Object?> payload,
    required String id,
    required String rawKind,
    required String title,
    required String? body,
    required DateTime createdAt,
    required DateTime? readAt,
    required NotificationSeverity severity,
  }) {
    String? str(String key) => switch (payload[key]) {
      final String v when v.isNotEmpty => v,
      _ => null,
    };
    return AppNotification(
      id: id,
      rawKind: rawKind,
      title: title,
      body: body,
      orderId: str('orderId'),
      paymentId: str('paymentId'),
      target: NotificationTarget.tryParse(payload['target']),
      rawTarget: str('target'),
      status: str('status'),
      cartId: str('cartId'),
      entity: SyncEntity.tryParse(str('entity')),
      runId: str('runId'),
      task: str('task'),
      outboxId: str('outboxId'),
      payload: payload,
      createdAt: createdAt,
      readAt: readAt,
      severity: severity,
    );
  }

  /// Строка кэша (правило DATA-258 для чувствительных видов применяет `NotificationsCacheDao`).
  static NotificationCacheEntry toCache(AppNotification n) => NotificationCacheEntry(
    id: n.id,
    kind: n.rawKind,
    severity: n.severity.value,
    title: n.title,
    body: n.body,
    payload: n.payload,
    createdAtMs: n.createdAt.toUtc().millisecondsSinceEpoch,
    readAtMs: n.readAt?.toUtc().millisecondsSinceEpoch,
  );

  /// Уведомление из кэша.
  static AppNotification fromCache(NotificationCacheRow r) {
    Map<String, Object?> payload = const <String, Object?>{};
    if (r.payloadJson != null) {
      try {
        final Object? decoded = jsonDecode(r.payloadJson!);
        if (decoded is Map) payload = decoded.cast<String, Object?>();
      } on FormatException {
        payload = const <String, Object?>{};
      }
    }
    return _build(
      id: r.id,
      rawKind: r.kind,
      title: r.title,
      body: r.body,
      payload: payload,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt, isUtc: true),
      readAt: r.readAt == null ? null : DateTime.fromMillisecondsSinceEpoch(r.readAt!, isUtc: true),
      severity: NotificationSeverity.tryParse(r.severity) ?? NotificationSeverity.info,
    );
  }
}

/// `NotificationsUnreadCount`.
abstract final class UnreadCountDto {
  static const Set<String> jsonKeys = {'unreadCount'};
  static const Set<String> requiredKeys = {'unreadCount'};

  static int fromJson(JsonMap j) => jReqInt(j, 'unreadCount');
}

/// Ответ `GET /notifications`.
abstract final class NotificationsPageDto {
  static const Set<String> jsonKeys = {
    'items',
    'nextCursor',
    'hasMore',
    'totalEstimate',
    'isEstimate',
    'asOf',
    'unreadCount',
  };
  static const Set<String> requiredKeys = {'items', 'nextCursor', 'hasMore', 'unreadCount'};

  static NotificationsPage fromJson(JsonMap j) => NotificationsPage(
    items: jObjects(j, 'items', NotificationDto.fromJson, required: true),
    unreadCount: jReqInt(j, 'unreadCount'),
    nextCursor: jOpt<String>(j, 'nextCursor'),
    hasMore: jBool(j, 'hasMore') ?? false,
  );
}
