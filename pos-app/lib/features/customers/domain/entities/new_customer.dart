// SCR-26 «Новый клиент»: запрос `POST /customers` (08 §4.11.2) и исход с дедупликацией по 1С/POS
// (`409 CUSTOMER_DUPLICATE_SUSPECTED` + `candidates[]`, D-08, RM-D-005). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';

/// Тело `POST /customers` (`CustomersCreateRequest`).
final class NewCustomerRequest {
  const NewCustomerRequest({
    required this.name,
    required this.customerType,
    required this.phonesE164,
    this.inn,
    this.address,
    this.comment,
    this.priceListId,
    this.forceCreate = false,
    this.forceReason,
  });

  /// 2…150 символов.
  final String name;
  final CustomerType customerType;

  /// 1…5 телефонов `+996XXXXXXXXX`.
  final List<String> phonesE164;

  /// ИНН КР — 14 цифр.
  final String? inn;

  /// ≤ 300 символов.
  final String? address;

  /// ≤ 500 символов.
  final String? comment;
  final String? priceListId;

  /// «Всё равно создать» — только `customer.create.force` (cashier, senior_seller, admin; Q-025).
  final bool forceCreate;

  /// 5…200 символов; обязательна при [forceCreate], запрещена без него.
  final String? forceReason;

  static const int nameMin = 2;
  static const int nameMax = 150;
  static const int phonesMax = 5;
  static const int addressMax = 300;
  static const int commentMax = 500;
  static const int forceReasonMin = 5;
  static const int forceReasonMax = 200;
}

/// Кандидат-дубль из `409 CUSTOMER_DUPLICATE_SUSPECTED` (ограниченные поля).
final class DuplicateCandidate {
  const DuplicateCandidate({required this.id, required this.displayName, this.phoneMasked, this.source});

  final String id;
  final String displayName;
  final String? phoneMasked;
  final CustomerSource? source;
}

/// Исход создания клиента.
sealed class NewCustomerOutcome {
  const NewCustomerOutcome();
}

/// Клиент создан (`source=pos`, `onecStatus=pending`).
final class NewCustomerCreated extends NewCustomerOutcome {
  const NewCustomerCreated(this.customer, {this.warningCodes = const <String>[]});

  final Customer customer;

  /// Коды `warnings[]` ответа `201` (08 §2.4 «Предупреждения»; операция применена) — как пришли.
  final List<String> warningCodes;

  /// `STALE_DATA`: проверка дублей в 1С не выполнялась — возможен дубль (02 UI-26-016, 10 CUST-012).
  bool get onecCheckSkipped => warningCodes.contains('STALE_DATA');
}

/// Найдены похожие клиенты: выбрать существующего или «Всё равно создать» (`forceCreate`) тем же ключом нельзя —
/// тело другое, нужен новый `Idempotency-Key`.
final class NewCustomerDuplicates extends NewCustomerOutcome {
  const NewCustomerDuplicates(this.candidates);

  final List<DuplicateCandidate> candidates;
}
