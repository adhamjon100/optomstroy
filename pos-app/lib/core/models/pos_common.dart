// Общие значения домена POS этапа F (08 §3.3–§3.10), которые нужны нескольким фичам, не связанным в DAG 06 §6.1
// (cart ↛ orders, orders ↛ cart): страница списка, предупреждение ответа, ссылка на пользователя, количество строки,
// получатель и доставка. Чистый Dart (как core/error): без flutter, dio, drift, riverpod; деньги — `Money`
// (тыйыны), количества — `Qty` (milli-units), D-19.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/qty.dart';

/// Страница списка (`Page<T>`, 08 §2.5).
final class PageResult<T> {
  const PageResult({
    required this.items,
    this.nextCursor,
    this.hasMore = false,
    this.totalEstimate,
    this.isEstimate = false,
    this.asOf,
  });

  final List<T> items;

  /// Непрозрачный курсор следующей страницы; `null` — страниц больше нет.
  final String? nextCursor;
  final bool hasMore;

  /// Оценка общего числа (`totalEstimate`; для `GET /orders` — точное число по фильтру).
  final int? totalEstimate;
  final bool isEstimate;

  /// Метка актуальности данных (`asOf`).
  final DateTime? asOf;
}

/// Предупреждение успешного ответа (`Warning`, 08 §2.4): операция применена, повторять не нужно.
final class ApiWarning {
  const ApiWarning({required this.rawCode, this.message = ''});

  /// Код как пришёл (неизвестный код сохраняется — совместимость вперёд).
  final String rawCode;

  /// Локализованный сервером текст (`Accept-Language`); показывается как есть, клиент его не разбирает.
  final String message;

  /// Код из словаря `WarningCode`; `null` — неизвестный.
  WarningCode? get code => WarningCode.tryParse(rawCode);

  @override
  String toString() => 'ApiWarning($rawCode)';
}

/// Ссылка на пользователя (`UserRef`).
final class UserRef {
  const UserRef({required this.id, required this.displayName, this.role});

  final String id;
  final String displayName;
  final RoleCode? role;
}

/// Количество строки (`Quantity`): [value] — в единицах выбранной упаковки (целое при [packagingId], INV-006),
/// [baseValue] — в базовой единице, считает сервер (POS-004).
final class LineQuantity {
  const LineQuantity({required this.value, required this.unitId, this.packagingId, this.baseValue});

  final Qty value;
  final String unitId;
  final String? packagingId;
  final Qty? baseValue;
}

/// Получатель заказа (`Receiver`). ПДн получателя ([name], [phoneE164]) клиент не сохраняет на диск
/// (`checkout_draft` — без ПДн, ядро §19.4) и не логирует.
final class Receiver {
  const Receiver({required this.kind, this.name, this.phoneE164});

  /// Получатель — сам клиент.
  const Receiver.customer() : kind = ReceiverKind.customer, name = null, phoneE164 = null;

  final ReceiverKind kind;
  final String? name;

  /// `+996XXXXXXXXX` (PhoneE164).
  final String? phoneE164;

  @override
  String toString() => 'Receiver(${kind.value})';
}

/// Получение заказа (`Delivery`): самовывоз или доставка. `geo` («Выбрать на карте») — R2 (Q-178), поля нет.
final class Delivery {
  const Delivery({
    required this.method,
    this.address,
    this.recipientPhoneE164,
    this.courierComment,
    this.desiredDate,
    this.timeFrom,
    this.timeTo,
  });

  /// Самовывоз.
  const Delivery.pickup()
    : method = DeliveryMethod.pickup,
      address = null,
      recipientPhoneE164 = null,
      courierComment = null,
      desiredDate = null,
      timeFrom = null,
      timeTo = null;

  /// Максимальная длина адреса (08 `Delivery.address`, 02 SCR-21, RM-F-013).
  static const int addressMaxLength = 300;

  /// Максимальная длина комментария курьеру.
  static const int commentMaxLength = 200;

  final DeliveryMethod method;

  /// Адрес (≤ 300); ПДн — на диск не пишется.
  final String? address;
  final String? recipientPhoneE164;
  final String? courierComment;

  /// Желаемая дата (только дата, `format: date`).
  final DateTime? desiredDate;

  /// Время «с»/«до» — `HH:mm`.
  final String? timeFrom;
  final String? timeTo;

  @override
  String toString() => 'Delivery(${method.value})';
}

/// Отметки печати после создания заказа (`PrintOptions`).
final class PrintOptions {
  const PrintOptions({this.invoice, this.waybill, this.receipt});

  final bool? invoice;
  final bool? waybill;
  final bool? receipt;
}
