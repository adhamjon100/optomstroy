// Порт долгов клиента (SCR-32 `ReceivableBadge`, SCR-34, SCR-30 «Долги и просрочки», SCR-48 → SCR-34; 08 §4.11.7,
// §4.11.8, §4.13; RM-G-002, RM-G-011, RM-G-012). Долги — только из 1С, fail-closed (D-24).
//
// Финансовые данные клиента (CASH-015, 07 §11.1 п. 5, DATA-258/264): только память текущей сессии —
// [CustomerFinanceMemory]; не drift, не secure storage. Офлайн экран показывает только то, что уже в памяти сессии.
// Детализация (`include=documents`) — step-up при первом просмотре и повторно через 15 мин (R0 §17.2): токен
// подставляет AuthInterceptor из кэша step-up (core/session) или повторяет запрос после StepUpDialog. Чистый Dart.
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';

/// Параметры `GET /receivables/overdue`.
final class OverdueReceivablesQuery {
  const OverdueReceivablesQuery({this.minOverdueDays, this.minAmount, this.limit, this.cursor, this.sort});

  final int? minOverdueDays;
  final Money? minAmount;
  final int? limit;
  final String? cursor;
  final OverdueSort? sort;
}

abstract interface class ReceivablesRepository {
  /// Снимок долга (`GET /customers/{id}/receivables`); [withDocuments] — детализация (step-up), [refresh] — попросить
  /// сервер попытаться обновить устаревший снимок. Успешный ответ кладётся в [CustomerFinanceMemory].
  Future<Result<Receivable>> get(
    String customerId, {
    bool withDocuments = false,
    bool refresh = false,
    String? stepUpToken,
  });

  /// «Обновить» (`POST /customers/{id}/receivables/refresh`; cashier, senior_seller, admin, owner; 429 — частота).
  Future<Result<Receivable>> refresh(
    String customerId, {
    bool withDocuments = false,
    String? idempotencyKey,
    String? stepUpToken,
  });

  /// Просроченная задолженность (`GET /receivables/overdue`).
  Future<Result<OverdueReceivablesPage>> overdue(OverdueReceivablesQuery query);
}

/// Память финансовых данных клиентов текущей сессии (CASH-015). Сбрасывается при смене пользователя / выходе.
abstract interface class CustomerFinanceMemory {
  /// Последний снимок долга клиента в этой сессии или `null`.
  Receivable? receivable(String customerId);

  void putReceivable(Receivable value);

  /// Забыть всё (выход, смена пользователя, блокировка по решению экрана).
  void clear();
}

/// Реализация [CustomerFinanceMemory] в памяти процесса.
final class InMemoryCustomerFinanceMemory implements CustomerFinanceMemory {
  final Map<String, Receivable> _receivables = <String, Receivable>{};

  @override
  Receivable? receivable(String customerId) => _receivables[customerId];

  @override
  void putReceivable(Receivable value) {
    final Receivable? prev = _receivables[value.customerId];
    // Снимок без детализации не затирает уже показанную детализацию того же снимка.
    if (value.documents == null && prev?.documents != null && prev!.asOf == value.asOf) return;
    _receivables[value.customerId] = value;
  }

  @override
  void clear() => _receivables.clear();
}
