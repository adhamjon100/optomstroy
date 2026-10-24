// Порт клиентов для этапа F (CustomerPicker SCR-21, CustomerCard, SCR-26). Только онлайн: кэша клиентов на
// устройстве нет (07 §11.1 п.5), поиск — с правилами антиперебора по ролям на сервере (ядро §19.4, 11 SEC-042).
// Экраны клиентов SCR-31…SCR-35 (этап G) расширяют порт. Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';

/// Параметры `GET /search/customers`.
final class CustomerSearchQuery {
  const CustomerSearchQuery({
    required this.q,
    this.favoriteOnly = false,
    this.withReceivable = false,
    this.limit = 20,
    this.cursor,
  });

  /// Строка поиска (1…200); `seller` — только полный номер или код клиента, иначе `VALIDATION_FAILED`
  /// (rule `search_scope_role`).
  final String q;
  final bool favoriteOnly;

  /// `include=receivable` — суммы долга (только `customer.receivables.read.summary`; для `seller` игнорируется).
  final bool withReceivable;

  /// 1…50.
  final int limit;
  final String? cursor;
}

abstract interface class CustomersRepository {
  /// Поиск клиентов (`GET /search/customers`); [cancel] — отмена устаревшего запроса (D-31, SCR-31.11).
  Future<Result<PageResult<Customer>>> search(CustomerSearchQuery query, {CancelSignal? cancel});

  /// Карточка клиента (`GET /customers/{id}`); поля — по роли.
  Future<Result<Customer>> get(String customerId);

  /// Создать клиента (`POST /customers`, `Idempotency-Key` обязателен). `409 CUSTOMER_DUPLICATE_SUSPECTED` —
  /// не ошибка, а [NewCustomerDuplicates].
  Future<Result<NewCustomerOutcome>> create(NewCustomerRequest request, {required String idempotencyKey});
}
