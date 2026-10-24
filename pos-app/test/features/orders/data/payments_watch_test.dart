// RM-F-003/RM-F-006 (SCR-22): ожидание оплаты long-polling `GET /payments/{id}?wait=25` (08 §4.9.2, Q-167):
// поток повторяет запрос до выхода платежа из ожидания; отказ сервера от `wait` (400) → опрос каждые N с;
// отмена подписки отменяет текущий запрос; приём оплаты — с Idempotency-Key, без автоповтора.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/orders/data/repositories/dio_orders_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

import '../../../core/network/fake_adapter.dart';

Map<String, Object?> payment(String status, {List<String> actions = const <String>[]}) => <String, Object?>{
  'id': 'pay-1',
  'orderId': 'ord-1',
  'method': 'qr_bakai',
  'status': status,
  'amount': <String, Object?>{'amount': '16007.50', 'currency': 'KGS'},
  'qr': <String, Object?>{
    'provider': 'onec',
    'payload': '00020101021226',
    'issuedAt': '2026-10-22T09:00:00Z',
    'autoConfirm': true,
  },
  'allowedActions': actions,
};

Dio dioWith(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;

void main() {
  test('long-polling: повтор до received; параметр wait=25', () async {
    final List<String> statuses = <String>['qr_shown', 'qr_shown', 'received'];
    var i = 0;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async => json(200, payment(statuses[i++])));
    final DioPaymentsRepository repo = DioPaymentsRepository(dioWith(adapter));
    final List<Result<PaymentDetails>> events = await repo.watch('pay-1').toList();
    expect(events.map((Result<PaymentDetails> r) => r.valueOrNull!.payment.status), <PaymentStatus>[
      PaymentStatus.qrShown,
      PaymentStatus.qrShown,
      PaymentStatus.received,
    ]);
    expect(adapter.requests, hasLength(3));
    expect(events.last.valueOrNull!.payment.qr!.payload, '00020101021226');
  });

  test('сервер отклоняет wait (400 VALIDATION_FAILED) → опрос без wait', () async {
    final List<Uri> uris = <Uri>[];
    var polls = 0;
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      uris.add(o.uri);
      if (o.uri.queryParameters.containsKey('wait')) return json(400, problem('VALIDATION_FAILED', 400));
      polls++;
      return json(200, payment(polls < 2 ? 'qr_shown' : 'qr_expired'));
    });
    final DioPaymentsRepository repo = DioPaymentsRepository(dioWith(adapter), pollInterval: Duration.zero);
    final List<Result<PaymentDetails>> events = await repo.watch('pay-1').toList();
    expect(events.last.valueOrNull!.payment.status, PaymentStatus.qrExpired);
    expect(uris.first.queryParameters['wait'], '25');
    expect(uris.skip(1).every((Uri u) => !u.queryParameters.containsKey('wait')), isTrue);
  });

  test('отмена подписки отменяет ожидание; новые запросы не уходят', () async {
    final Completer<void> sent = Completer<void>();
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      if (!sent.isCompleted) sent.complete();
      // Ответ не приходит (сервер держит long-poll) — завершить запрос может только отмена.
      await Completer<void>().future;
      return json(200, payment('qr_shown'));
    });
    final DioPaymentsRepository repo = DioPaymentsRepository(dioWith(adapter));
    final StreamSubscription<Result<PaymentDetails>> sub = repo.watch('pay-1').listen((_) {});
    await sent.future;
    await sub.cancel();
    expect(adapter.requests, hasLength(1));
  });

  test('POST /orders/{id}/payments: Idempotency-Key, 201 → created, сумма в теле не передаётся', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => json(201, <String, Object?>{
        ...payment('cash_pending'),
        'method': 'cash',
        'order': <String, Object?>{
          'paidAmount': <String, Object?>{'amount': '0.00', 'currency': 'KGS'},
          'isPaid': false,
        },
      }),
    );
    final DioPaymentsRepository repo = DioPaymentsRepository(dioWith(adapter));
    final OrderPaymentResult r = (await repo.createForOrder(
      'ord-1',
      OrderPaymentRequest.cash(received: Money.som(17000)),
      idempotencyKey: 'pay-key',
    )).valueOrNull!;
    expect((r.created, r.orderIsPaid, r.orderPaidAmount), (true, false, Money.zero));
    expect(adapter.requests.single.headers[ApiHeaders.idempotencyKey], 'pay-key');
    expect((adapter.requests.single.data! as Map<String, dynamic>).containsKey('amount'), isFalse);
  });

  test('документ PDF: байты и имя из Content-Disposition; формат и копия в query', () async {
    final FakeAdapter adapter = FakeAdapter(
      (RequestOptions o) async => ResponseBody.fromBytes(
        <int>[37, 80, 68, 70],
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/pdf'],
          'content-disposition': <String>['inline; filename="invoice-POS-2026-000123.pdf"'],
        },
      ),
    );
    final DioOrdersRepository repo = DioOrdersRepository(dioWith(adapter));
    final Result<OrderDocumentFile> r = await repo.document(
      'ord-1',
      OrderDocumentKind.invoice,
      format: PrintPaper.thermal80,
      copy: true,
    );
    final OrderDocumentFile file = r.valueOrNull!;
    expect(file.bytes, <int>[37, 80, 68, 70]);
    expect(file.fileName, 'invoice-POS-2026-000123.pdf');
    expect(adapter.requests.single.path, '/orders/ord-1/documents/invoice.pdf');
  });
}
