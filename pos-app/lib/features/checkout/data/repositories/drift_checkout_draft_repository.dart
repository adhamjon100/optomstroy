// `CheckoutDraftRepository` на drift `checkout_draft` БД текущего пользователя (07 §11.2; DATA-263). БД закрыта
// (до входа, после выхода) → `UnknownFailure(CheckoutDraftUnavailable)`: оформление без черновика невозможно —
// ключ `POST /orders` обязан пережить перезапуск (ядро §22.6).
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/checkout_draft_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';
import 'package:uuid/uuid.dart';

/// Причина `UnknownFailure`: БД пользователя не открыта.
final class CheckoutDraftUnavailable {
  const CheckoutDraftUnavailable();

  @override
  String toString() => 'CheckoutDraftUnavailable';
}

final class DriftCheckoutDraftRepository implements CheckoutDraftRepository {
  DriftCheckoutDraftRepository({
    required AppDatabase? Function() database,
    required Clock clock,
    String Function()? newKey,
  }) : _db = database,
       _clock = clock,
       _newKey = newKey ?? const Uuid().v4;

  final AppDatabase? Function() _db;
  final Clock _clock;
  final String Function() _newKey;

  Future<Result<T>> _run<T>(Future<T> Function(CheckoutDraftDao dao) body) async {
    final AppDatabase? db = _db();
    if (db == null) return const FailureResult(UnknownFailure(cause: CheckoutDraftUnavailable()));
    try {
      return Success<T>(await body(CheckoutDraftDao(db)));
    } on Object catch (e) {
      return FailureResult<T>(UnknownFailure(cause: e));
    }
  }

  int get _now => _clock.nowUtc().millisecondsSinceEpoch;

  static CheckoutDraft _draft(CheckoutDraftRow r) => CheckoutDraft(
    localCartId: r.localCartId,
    step: CheckoutStep.parse(r.step),
    customerId: r.customerId,
    deliveryMethod: DeliveryMethod.tryParse(r.deliveryMethod),
    receiverKind: ReceiverKind.tryParse(r.receiverKind),
    paymentMethod: PaymentMethod.tryParse(r.paymentMethod),
    orderIdempotencyKey: r.orderIdempotencyKey,
    submittedAt: r.submittedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(r.submittedAt!, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(r.updatedAt, isUtc: true),
  );

  @override
  Future<Result<CheckoutDraft?>> load(String localCartId) => _run((CheckoutDraftDao dao) async {
    final CheckoutDraftRow? row = await dao.find(localCartId);
    return row == null ? null : _draft(row);
  });

  @override
  Future<Result<CheckoutDraft>> save(CheckoutDraft draft) => _run(
    (CheckoutDraftDao dao) async => _draft(
      await dao.upsertSelection(
        localCartId: draft.localCartId,
        step: draft.step.value,
        nowMs: _now,
        customerId: draft.customerId,
        deliveryMethod: draft.deliveryMethod?.value,
        receiverKind: draft.receiverKind?.value,
        paymentMethod: draft.paymentMethod?.value,
      ),
    ),
  );

  @override
  Future<Result<String>> ensureOrderKey(String localCartId) =>
      _run((CheckoutDraftDao dao) => dao.ensureOrderKey(localCartId, newKey: _newKey(), nowMs: _now));

  @override
  Future<Result<void>> markSubmitted(String localCartId) =>
      _run((CheckoutDraftDao dao) => dao.markSubmitted(localCartId, nowMs: _now));

  @override
  Future<Result<void>> clear(String localCartId) => _run((CheckoutDraftDao dao) => dao.delete(localCartId));

  @override
  Future<Result<List<CheckoutDraft>>> pendingSubmissions() => _run(
    (CheckoutDraftDao dao) async => <CheckoutDraft>[
      for (final CheckoutDraftRow r in await dao.submittedPending()) _draft(r),
    ],
  );
}
