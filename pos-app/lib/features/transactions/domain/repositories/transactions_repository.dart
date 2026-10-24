// Порт журнала операций (SCR-36, SCR-37; 08 §4.16). Только онлайн: транзакции — финансовые данные, на устройстве не
// кэшируются (CASH-015). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/transactions/domain/entities/transactions_query.dart';

abstract interface class TransactionsRepository {
  /// `GET /transactions`.
  Future<Result<TransactionsPage>> list(TransactionsQuery query);

  /// `GET /transactions/{id}`.
  Future<Result<TransactionDetail>> get(String transactionId);
}
