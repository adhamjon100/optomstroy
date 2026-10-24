// Память незавершённых финансовых операций (02 ч. D §0.3 п. 5(б) P-IDEMP; SCR-30 п. 11; 07 DATA-263; CASH-015):
// ключи — только в пределах сеанса; выход → вход того же пользователя — память пуста (ревью G-flutter-data-2:
// провайдер без слушателей на момент выхода пересобирается и при возврате того же `userId`); поиск по заказу —
// любого вида операции (ревью G-flutter-ui-2).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/cashier/presentation/state/unfinished_operations.dart';

final class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(status: SessionStatus.authenticated, userId: 'u-a');

  void set(SessionState s) => state = s;
}

const UnfinishedOperation _op = UnfinishedOperation(
  kind: UnfinishedKind.orderPayment,
  idempotencyKey: 'key-1',
  orderId: 'o1',
);

void main() {
  late _Session session;
  late ProviderContainer container;

  setUp(() {
    session = _Session();
    container = ProviderContainer(overrides: [sessionControllerProvider.overrideWith(() => session)]);
    addTearDown(container.dispose);
  });

  test('выход → вход того же пользователя без слушателей памяти — незавершённых операций нет', () async {
    container.read(sessionControllerProvider);
    container.read(cashierUnfinishedOperationsProvider.notifier).put(_op);
    expect(container.read(cashierUnfinishedOperationsProvider), hasLength(1));

    // Ветка «Касса» не смонтирована: память никто не слушает (senior_seller принимал оплату с SCR-24).
    session.set(const SessionState(status: SessionStatus.unauthenticated));
    await Future<void>.delayed(Duration.zero);
    session.set(const SessionState(status: SessionStatus.authenticated, userId: 'u-a'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(cashierUnfinishedOperationsProvider), isEmpty);
  });

  test('выход → вход того же пользователя при активном слушателе — память пуста', () async {
    final ProviderSubscription<List<UnfinishedOperation>> sub = container.listen(
      cashierUnfinishedOperationsProvider,
      (_, _) {},
    );
    addTearDown(sub.close);
    container.read(cashierUnfinishedOperationsProvider.notifier).put(_op);
    session.set(const SessionState(status: SessionStatus.unauthenticated));
    await Future<void>.delayed(Duration.zero);
    session.set(const SessionState(status: SessionStatus.authenticated, userId: 'u-a'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(cashierUnfinishedOperationsProvider), isEmpty);
  });

  test('блокировка сессии (тот же пользователь) память не очищает', () async {
    container.read(cashierUnfinishedOperationsProvider.notifier).put(_op);
    session.set(const SessionState(status: SessionStatus.authenticated, userId: 'u-a', lock: SessionLockReason.idle));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(cashierUnfinishedOperationsProvider), hasLength(1));
  });

  test('forOrder без вида — операция любого вида; remove по ключу — запись любого вида', () {
    final UnfinishedOperationsNotifier n = container.read(cashierUnfinishedOperationsProvider.notifier);
    n.put(
      const UnfinishedOperation(
        kind: UnfinishedKind.confirmManual,
        idempotencyKey: 'key-c',
        orderId: 'o1',
        paymentId: 'pay-qr',
      ),
    );
    expect(n.forOrder('o1')?.idempotencyKey, 'key-c');
    expect(n.forOrder('o1', kind: UnfinishedKind.orderPayment), isNull);
    expect(n.forOrder('o1', kind: UnfinishedKind.confirmManual)?.kind, UnfinishedKind.confirmManual);
    expect(n.forOrder('o2'), isNull);
    n.remove('key-c');
    expect(n.forOrder('o1'), isNull);
  });
}
