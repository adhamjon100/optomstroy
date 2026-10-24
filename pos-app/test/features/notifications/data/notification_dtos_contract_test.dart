// ADR-085, RM-F-008: ручные DTO уведомлений == contracts/openapi/pos-api.v1.yaml 1.2.0 (`Notification`,
// `NotificationsUnreadCount`, ответ `GET /notifications`); репозиторий пишет ответ в `notifications_cache` по правилу
// DATA-258 (без `body` у `credit_blocked`/`payment_status`/`return_status`).
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/notifications/data/dto/notification_dtos.dart';
import 'package:optomstroy/features/notifications/data/repositories/notifications_repository_impl.dart';
import 'package:optomstroy/features/notifications/domain/entities/app_notification.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const String _list = '/notifications get 200';

void main() {
  configureSqliteForTests();
  final OpenApiSchemas? api = OpenApiSchemas.load(
    const <String>['Notification', 'NotificationsUnreadCount'],
    responses: const <String>[_list],
  );
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  test('ключи и обязательные поля == схемы OpenAPI', () {
    expect(NotificationDto.jsonKeys, api!.props('Notification'));
    expect(NotificationDto.requiredKeys, api.required('Notification'));
    expect(UnreadCountDto.jsonKeys, api.props('NotificationsUnreadCount'));
    expect(UnreadCountDto.requiredKeys, api.required('NotificationsUnreadCount'));
    expect(NotificationsPageDto.jsonKeys, api.responseProps(_list));
    expect(NotificationsPageDto.requiredKeys, api.responseRequired(_list));
    final Map<String, dynamic> payload = api.example('Notification')['payload'] as Map<String, dynamic>;
    expect(payload.keys.toSet(), NotificationDto.payloadKeys);
  }, skip: skip);

  test('пример ответа GET /notifications разбирается', () {
    final NotificationsPage page = NotificationsPageDto.fromJson(jsonCopy(api!.responseExample(_list)));
    expect(page.unreadCount, 1);
    final AppNotification n = page.items.single;
    expect(n.kind, NotificationKind.syncError);
    expect(n.severity, NotificationSeverity.info);
    expect(n.target, NotificationTarget.sessions);
    expect(n.orderId, isNotEmpty);
    // OpenAPI 1.2.0 (08 §3.13 «Ключи Notification.payload»).
    expect(n.paymentId, isNotEmpty);
    expect(n.cartId, isNotEmpty);
    expect(n.runId, isNotEmpty);
    expect(n.outboxId, isNotEmpty);
    expect(n.status, isNotEmpty);
    expect(n.task, isNotEmpty);
    expect(n.entity, isNotNull);
  }, skip: skip);

  test(
    'payload 1.2.0: cart_parked + cartId, entity, task; неизвестные значения и типы не ломают разбор (08 §2.11)',
    () {
      AppNotification parse(Map<String, Object?> payload) => NotificationDto.fromJson(<String, dynamic>{
        'id': 'n-1',
        'kind': 'system',
        'title': 't',
        'createdAt': '2026-10-23T09:00:00Z',
        'severity': 'info',
        'payload': payload,
      });
      final AppNotification parked = parse(<String, Object?>{
        'target': 'cart_parked',
        'cartId': 'c-1',
        'task': 'refund_or_advance',
        'entity': 'order_status',
        'status': 'confirmed',
      });
      expect(parked.target, isNull, reason: 'cart_parked — через rawTarget (switch экрана не ломается)');
      expect(parked.rawTarget, AppNotification.targetCartParked);
      expect(parked.cartId, 'c-1');
      expect(parked.task, AppNotification.taskRefundOrAdvance);
      expect(parked.entity, SyncEntity.orderStatus);
      expect(parked.status, 'confirmed');
      final AppNotification odd = parse(<String, Object?>{
        'target': 'future',
        'entity': 'future',
        'runId': 42,
        'cartId': '',
      });
      expect((odd.target, odd.rawTarget, odd.entity, odd.runId, odd.cartId), (null, 'future', null, null, null));
    },
  );

  group('репозиторий + кэш', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('ответ сервера кэшируется; у payment_status body не сохраняется, payload — только идентификаторы', () async {
      final FakeAdapter adapter = FakeAdapter(
        (RequestOptions o) async => json(200, <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': 'n-1',
              'kind': 'payment_status',
              'title': 'Оплата получена',
              'body': 'сумма и клиент',
              'payload': <String, Object?>{'orderId': 'o-1', 'paymentId': 'p-1', 'customerName': 'ПДн'},
              'createdAt': '2026-10-22T09:00:00Z',
              'severity': 'info',
            },
            <String, Object?>{
              'id': 'n-2',
              'kind': 'order_status',
              'title': 'Заказ согласован',
              'body': 'Заказ № POS-1',
              'payload': <String, Object?>{'orderId': 'o-2'},
              'createdAt': '2026-10-22T09:01:00Z',
              'severity': 'info',
            },
          ],
          'nextCursor': null,
          'hasMore': false,
          'unreadCount': 2,
        }),
      );
      final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
      final NotificationsRepositoryImpl repo = NotificationsRepositoryImpl(
        dio,
        database: () => db,
        clock: FixedClock(DateTime.utc(2026, 10, 22, 10)),
      );
      final Result<NotificationsPage> r = await repo.list(const NotificationsQuery(unreadOnly: true));
      expect(r.valueOrNull!.unreadCount, 2);
      expect(adapter.requests.single.path, '/notifications');
      final List<NotificationCacheRow> rows = await db.select(db.notificationsCache).get();
      final NotificationCacheRow payment = rows.firstWhere((NotificationCacheRow r) => r.id == 'n-1');
      expect(payment.body, isNull);
      expect(payment.payloadJson, '{"orderId":"o-1","paymentId":"p-1"}');
      expect(rows.firstWhere((NotificationCacheRow r) => r.id == 'n-2').body, 'Заказ № POS-1');
      expect(await repo.watchCachedUnreadCount().first, 2);
      final List<AppNotification> cached = await repo.watchCached().first;
      expect(cached.map((AppNotification n) => n.id), <String>['n-2', 'n-1']);
    });
  });
}
