// GENERATED FILE — DO NOT EDIT.
// Source: contracts/enums.json (optomstroy-pos-enums 1.2.0, sha256 3e1a7b459ff5b94974e57aa4b3b82b2b88942b0c84fb3e21f8a60b1198357d0a)
// Generator: scripts/gen_enums.py (RM-B-009). Owners: 07 §6.1/§6.1.1, 08 §2.4/§3.8 (R0 §18.1).
// ignore_for_file: lines_longer_than_80_chars

const String enumsContractVersion = '1.2.0';

// ===== 07 §6.1 — типы PostgreSQL (CREATE TYPE … AS ENUM) =====

/// user_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: users.kind.
enum UserKind {
  staff('staff'),
  customer('customer');

  const UserKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static UserKind? tryParse(String? value) {
    for (final item in UserKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// user_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: users.status.
enum UserStatus {
  pending('pending'),
  pendingActivation('pending_activation'),
  active('active'),
  blocked('blocked'),
  deleted('deleted');

  const UserStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static UserStatus? tryParse(String? value) {
    for (final item in UserStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// role_code — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: roles.code, user_invitations.role, role_discount_limits.role, price_lists.visible_to_roles[], audit_logs.actor_role.
enum RoleCode {
  seller('seller'),
  cashier('cashier'),
  seniorSeller('senior_seller'),
  admin('admin'),
  owner('owner'),
  customer('customer'),
  integration('integration');

  const RoleCode(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static RoleCode? tryParse(String? value) {
    for (final item in RoleCode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// customer_link_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: customer_links.status.
enum CustomerLinkStatus {
  proposed('proposed'),
  confirmed('confirmed'),
  rejected('rejected'),
  conflict('conflict');

  const CustomerLinkStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CustomerLinkStatus? tryParse(String? value) {
    for (final item in CustomerLinkStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// cart_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: carts.status.
enum CartStatus {
  active('active'),
  parked('parked'),
  converted('converted'),
  cleared('cleared');

  const CartStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CartStatus? tryParse(String? value) {
    for (final item in CartStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// order_status — 07 §6.1 (CREATE TYPE). Источник: D-20.
/// Используется: orders.status, order_status_history.from_status/to_status.
enum OrderStatus {
  draft('draft'),
  submitting('submitting'),
  submitFailed('submit_failed'),
  pendingApproval('pending_approval'),
  awaitingPayment('awaiting_payment'),
  approved('approved'),
  awaitingShipment('awaiting_shipment'),
  shipped('shipped'),
  partiallyReturned('partially_returned'),
  closed('closed'),
  cancelled('cancelled');

  const OrderStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OrderStatus? tryParse(String? value) {
    for (final item in OrderStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// delivery_method — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: orders.delivery_method.
enum DeliveryMethod {
  pickup('pickup'),
  delivery('delivery');

  const DeliveryMethod(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static DeliveryMethod? tryParse(String? value) {
    for (final item in DeliveryMethod.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// receiver_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: orders.receiver_kind.
enum ReceiverKind {
  customer('customer'),
  otherPerson('other_person');

  const ReceiverKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReceiverKind? tryParse(String? value) {
    for (final item in ReceiverKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// payment_method — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: orders.payment_method, payments.method, transactions.payment_method, return_requests.refund_method_expected.
enum PaymentMethod {
  cash('cash'),
  qrBakai('qr_bakai'),
  credit('credit');

  const PaymentMethod(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static PaymentMethod? tryParse(String? value) {
    for (final item in PaymentMethod.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// payment_status — 07 §6.1 (CREATE TYPE). Источник: D-21.
/// Используется: payments.status.
enum PaymentStatus {
  initiated('initiated'),
  cashPending('cash_pending'),
  qrPending('qr_pending'),
  qrShown('qr_shown'),
  qrExpired('qr_expired'),
  manualConfirm('manual_confirm'),
  credit('credit'),
  received('received'),
  voided('voided'),
  refunded('refunded');

  const PaymentStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static PaymentStatus? tryParse(String? value) {
    for (final item in PaymentStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// return_request_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: return_requests.status.
enum ReturnRequestStatus {
  draft('draft'),
  submitted('submitted'),
  accepted('accepted'),
  rejected('rejected'),
  completed('completed');

  const ReturnRequestStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReturnRequestStatus? tryParse(String? value) {
    for (final item in ReturnRequestStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// transaction_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + §17.3, §18.2 п.10 (return_requested — could).
/// Используется: transactions.kind.
enum TransactionKind {
  orderCreated('order_created'),
  orderCancelled('order_cancelled'),
  paymentReceived('payment_received'),
  paymentVoided('payment_voided'),
  refund('refund'),
  discountOverride('discount_override'),
  creditSaleApproved('credit_sale_approved'),
  manualQrConfirm('manual_qr_confirm'),
  returnRequested('return_requested');

  const TransactionKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static TransactionKind? tryParse(String? value) {
    for (final item in TransactionKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sync_entity — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + §17.3.
/// Используется: sync_runs.entity, sync_state.entity, sync_errors.entity, sync_entity_versions.entity.
enum SyncEntity {
  categories('categories'),
  products('products'),
  variants('variants'),
  attributes('attributes'),
  units('units'),
  barcodes('barcodes'),
  images('images'),
  warehouses('warehouses'),
  stock('stock'),
  prices('prices'),
  customers('customers'),
  receivables('receivables'),
  salesHistory('sales_history'),
  orderStatus('order_status'),
  discounts('discounts'),
  paymentDocs('payment_docs'),
  returnDocs('return_docs');

  const SyncEntity(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SyncEntity? tryParse(String? value) {
    for (final item in SyncEntity.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sync_mode — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: sync_runs.mode.
enum SyncMode {
  full('full'),
  incremental('incremental'),
  manual('manual'),
  reconcile('reconcile');

  const SyncMode(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SyncMode? tryParse(String? value) {
    for (final item in SyncMode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sync_run_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6.
/// Используется: sync_runs.status.
enum SyncRunStatus {
  queued('queued'),
  running('running'),
  success('success'),
  partial('partial'),
  failed('failed');

  const SyncRunStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SyncRunStatus? tryParse(String? value) {
    for (final item in SyncRunStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// outbox_status — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + v1.7 §22.1 (cancelled).
/// Используется: onec_outbox.status; автомат — §6.5.
enum OutboxStatus {
  pending('pending'),
  sending('sending'),
  sent('sent'),
  confirmed('confirmed'),
  failed('failed'),
  dead('dead'),
  cancelled('cancelled');

  const OutboxStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OutboxStatus? tryParse(String? value) {
    for (final item in OutboxStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// notification_kind — 07 §6.1 (CREATE TYPE). Источник: ядро §6 + §17.3.
/// Используется: notifications.kind.
enum NotificationKind {
  syncError('sync_error'),
  orderStatus('order_status'),
  cartPriceChanged('cart_price_changed'),
  cartStockChanged('cart_stock_changed'),
  creditBlocked('credit_blocked'),
  system('system'),
  paymentStatus('payment_status'),
  returnStatus('return_status');

  const NotificationKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static NotificationKind? tryParse(String? value) {
    for (final item in NotificationKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// invitation_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.3.
/// Используется: user_invitations.status.
enum InvitationStatus {
  pending('pending'),
  accepted('accepted'),
  revoked('revoked'),
  expired('expired');

  const InvitationStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static InvitationStatus? tryParse(String? value) {
    for (final item in InvitationStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// device_platform — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.8.
/// Используется: devices.platform.
enum DevicePlatform {
  android('android'),
  ios('ios'),
  windows('windows');

  const DevicePlatform(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static DevicePlatform? tryParse(String? value) {
    for (final item in DevicePlatform.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// session_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.9, R6 §2.2.
/// Используется: sessions.kind.
enum SessionKind {
  standard('standard'),
  biometric('biometric');

  const SessionKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SessionKind? tryParse(String? value) {
    for (final item in SessionKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// step_up_method — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.9.
/// Используется: sessions.step_up_method, audit_logs.step_up_method.
enum StepUpMethod {
  pin('pin'),
  biometric('biometric'),
  otp('otp');

  const StepUpMethod(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static StepUpMethod? tryParse(String? value) {
    for (final item in StepUpMethod.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// otp_purpose — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3, §18.2 п.7; карточка §5.11.
/// Используется: otp_challenges.purpose; тело POST /auth/otp/request (08).
/// Не используются: login.
enum OtpPurpose {
  loginOrRegister('login_or_register'),
  stepUp('step_up'),
  phoneChangeOld('phone_change_old'),
  phoneChangeNew('phone_change_new'),
  customerLink('customer_link');

  const OtpPurpose(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OtpPurpose? tryParse(String? value) {
    for (final item in OtpPurpose.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// otp_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.11.
/// Используется: otp_challenges.status.
enum OtpStatus {
  sent('sent'),
  verified('verified'),
  expired('expired'),
  locked('locked'),
  failedDelivery('failed_delivery'),
  superseded('superseded');

  const OtpStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OtpStatus? tryParse(String? value) {
    for (final item in OtpStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// consent_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3, §19.3; карточка §5.14.
/// Используется: consents.kind; DTO consents[].kind в POST /registration/complete (08).
enum ConsentKind {
  personalData('personal_data'),
  sms('sms'),
  biometricsDevice('biometrics_device'),
  activitySphere('activity_sphere'),
  faceScan('face_scan');

  const ConsentKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ConsentKind? tryParse(String? value) {
    for (final item in ConsentKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// attribute_value_type — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.18.
/// Используется: product_attributes.value_type.
enum AttributeValueType {
  text('text'),
  number('number'),
  boolean('boolean'),
  list('list');

  const AttributeValueType(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static AttributeValueType? tryParse(String? value) {
    for (final item in AttributeValueType.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// barcode_type — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.22.
/// Используется: barcodes.type.
enum BarcodeType {
  ean13('EAN13'),
  ean8('EAN8'),
  upc('UPC'),
  code128('CODE128'),
  code39('CODE39'),
  qr('QR'),
  other('other');

  const BarcodeType(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static BarcodeType? tryParse(String? value) {
    for (final item in BarcodeType.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// image_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.23.
/// Используется: product_images.status.
enum ImageStatus {
  pending('pending'),
  downloading('downloading'),
  ready('ready'),
  failed('failed'),
  missingSource('missing_source');

  const ImageStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ImageStatus? tryParse(String? value) {
    for (final item in ImageStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// customer_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.28.
/// Используется: customers.source.
enum CustomerSource {
  onec('onec'),
  pos('pos');

  const CustomerSource(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CustomerSource? tryParse(String? value) {
    for (final item in CustomerSource.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// customer_type — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3, §19.4; карточка §5.28.
/// Используется: customers.customer_type.
enum CustomerType {
  individual('individual'),
  entrepreneur('entrepreneur'),
  legal('legal');

  const CustomerType(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CustomerType? tryParse(String? value) {
    for (final item in CustomerType.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// customer_onec_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.28.
/// Используется: customers.onec_status.
enum CustomerOnecStatus {
  nA('n_a'),
  pending('pending'),
  confirmed('confirmed'),
  rejected('rejected'),
  duplicate('duplicate');

  const CustomerOnecStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CustomerOnecStatus? tryParse(String? value) {
    for (final item in CustomerOnecStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// contact_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.29.
/// Используется: customer_contacts.kind.
enum ContactKind {
  phone('phone'),
  address('address'),
  email('email'),
  other('other');

  const ContactKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ContactKind? tryParse(String? value) {
    for (final item in ContactKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// link_match_method — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.30.
/// Используется: customer_links.match_method.
enum LinkMatchMethod {
  phone('phone'),
  manualAdmin('manual_admin'),
  onecCreated('onec_created');

  const LinkMatchMethod(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static LinkMatchMethod? tryParse(String? value) {
    for (final item in LinkMatchMethod.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// discount_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.33.
/// Используется: discount_rules.source.
enum DiscountSource {
  onec('onec'),
  pos('pos');

  const DiscountSource(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static DiscountSource? tryParse(String? value) {
    for (final item in DiscountSource.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// discount_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.33.
/// Используется: discount_rules.kind.
enum DiscountKind {
  percent('percent'),
  fixedAmount('fixed_amount'),
  priceList('price_list');

  const DiscountKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static DiscountKind? tryParse(String? value) {
    for (final item in DiscountKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// status_change_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.39.
/// Используется: order_status_history.source.
enum StatusChangeSource {
  posUser('pos_user'),
  posSystem('pos_system'),
  onecSync('onec_sync'),
  onecResponse('onec_response');

  const StatusChangeSource(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static StatusChangeSource? tryParse(String? value) {
    for (final item in StatusChangeSource.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// transaction_source — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.44.
/// Используется: transactions.source.
enum TransactionSource {
  pos('pos'),
  onec('onec');

  const TransactionSource(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static TransactionSource? tryParse(String? value) {
    for (final item in TransactionSource.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// return_reason — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.45, R7 §6, ядро §17.3.
/// Используется: return_requests.reason, return_request_items.reason_override.
/// Не используются: excess.
enum ReturnReason {
  defect('defect'),
  wrongItem('wrong_item'),
  notSuitable('not_suitable'),
  surplus('surplus'),
  sellerError('seller_error'),
  other('other');

  const ReturnReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReturnReason? tryParse(String? value) {
    for (final item in ReturnReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sync_trigger — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.51.
/// Используется: sync_runs.trigger.
enum SyncTrigger {
  schedule('schedule'),
  manual('manual'),
  retry('retry'),
  dependency('dependency');

  const SyncTrigger(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SyncTrigger? tryParse(String? value) {
    for (final item in SyncTrigger.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// outbox_aggregate — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.55, ядро §17.3.
/// Используется: onec_outbox.aggregate_type (отмена заказа — order + operation='cancel').
enum OutboxAggregate {
  order('order'),
  payment('payment'),
  customer('customer'),
  returnRequest('return_request');

  const OutboxAggregate(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OutboxAggregate? tryParse(String? value) {
    for (final item in OutboxAggregate.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// idempotency_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.56.
/// Используется: idempotency_keys.status.
enum IdempotencyStatus {
  inProgress('in_progress'),
  completed('completed');

  const IdempotencyStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static IdempotencyStatus? tryParse(String? value) {
    for (final item in IdempotencyStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// audit_level — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.57.
/// Используется: audit_logs.level.
enum AuditLevel {
  app('app'),
  db('db');

  const AuditLevel(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static AuditLevel? tryParse(String? value) {
    for (final item in AuditLevel.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// print_document_kind — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.60.
/// Используется: print_jobs.document_kind.
enum PrintDocumentKind {
  invoice('invoice'),
  waybill('waybill'),
  receipt('receipt');

  const PrintDocumentKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static PrintDocumentKind? tryParse(String? value) {
    for (final item in PrintDocumentKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// print_job_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.60.
/// Используется: print_jobs.status.
enum PrintJobStatus {
  queued('queued'),
  ready('ready'),
  failed('failed'),
  unavailableOnec('unavailable_onec');

  const PrintJobStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static PrintJobStatus? tryParse(String? value) {
    for (final item in PrintJobStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sms_status — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §17.3; карточка §5.61.
/// Используется: sms_outbox.status.
enum SmsStatus {
  queued('queued'),
  sent('sent'),
  delivered('delivered'),
  failed('failed'),
  expired('expired');

  const SmsStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SmsStatus? tryParse(String? value) {
    for (final item in SmsStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// onec_sync_state — 07 §6.1 (CREATE TYPE). Источник: РЕШЕНИЕ: ядро §20.2 п.10; карточка §5.37, §6.5.
/// Используется: orders.onec_sync_state.
enum OnecSyncState {
  unknown('unknown'),
  pending('pending'),
  linked('linked'),
  missing('missing'),
  ambiguous('ambiguous');

  const OnecSyncState(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OnecSyncState? tryParse(String? value) {
    for (final item in OnecSyncState.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

// ===== 07 §6.1.1 — CHECK-перечни текстовых полей =====

/// locale — 07 §6.1.1 (CHECK). Поля: user_profiles.locale.
/// Источник: проектное.
enum Locale {
  ru('ru'),
  ky('ky'),
  en('en');

  const Locale(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static Locale? tryParse(String? value) {
    for (final item in Locale.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// invitation_role — 07 §6.1.1 (CHECK). Поля: user_invitations.role.
/// Источник: D-07, D-15.
enum InvitationRole {
  seller('seller'),
  cashier('cashier'),
  seniorSeller('senior_seller'),
  admin('admin'),
  owner('owner');

  const InvitationRole(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static InvitationRole? tryParse(String? value) {
    for (final item in InvitationRole.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// session_revoke_reason — 07 §6.1.1 (CHECK). Поля: sessions.revoke_reason.
/// Источник: D-12, ядро §18.2 п.8; 09 §8.3, миграция 0003 (EQ-AUTH-03, ADR-088).
enum SessionRevokeReason {
  logout('logout'),
  logoutAll('logout_all'),
  reuseDetected('reuse_detected'),
  admin('admin'),
  phoneChanged('phone_changed'),
  roleChanged('role_changed'),
  expired('expired'),
  deviceRevoked('device_revoked'),
  blocked('blocked'),
  sessionLimit('session_limit'),
  deviceMismatch('device_mismatch'),
  biometricInvalidated('biometric_invalidated'),
  refreshReplay('refresh_replay');

  const SessionRevokeReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SessionRevokeReason? tryParse(String? value) {
    for (final item in SessionRevokeReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// token_kind — 07 §6.1.1 (CHECK). Поля: token_denylist.token_kind.
/// Источник: ядро §17.3, §18.2 п.6.
enum TokenKind {
  access('access'),
  registration('registration'),
  stepUp('step_up');

  const TokenKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static TokenKind? tryParse(String? value) {
    for (final item in TokenKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// token_deny_reason — 07 §6.1.1 (CHECK). Поля: token_denylist.reason.
/// Источник: ядро §18.2 п.6.
enum TokenDenyReason {
  logout('logout'),
  logoutAll('logout_all'),
  roleChanged('role_changed'),
  blocked('blocked'),
  used('used'),
  revoked('revoked');

  const TokenDenyReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static TokenDenyReason? tryParse(String? value) {
    for (final item in TokenDenyReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// rate_limit_scope — 07 §6.1.1 (CHECK). Поля: rate_limit_counters.scope.
/// Источник: D-10, D-44; миграция 0003 (EQ-AUTH-01, ADR-088).
enum RateLimitScope {
  otpPhone15m('otp_phone_15m'),
  otpPhone24h('otp_phone_24h'),
  otpIp1h('otp_ip_1h'),
  otpDevice24h('otp_device_24h'),
  loginIp1h('login_ip_1h'),
  stepUpUser1h('step_up_user_1h'),
  webhookIp1m('webhook_ip_1m'),
  otpIp10m('otp_ip_10m'),
  otpIp24h('otp_ip_24h'),
  otpDevice10m('otp_device_10m'),
  otpGlobal1m('otp_global_1m'),
  otpVerifyIp10m('otp_verify_ip_10m'),
  pinUserDevice10m('pin_user_device_10m'),
  adminUser1m('admin_user_1m');

  const RateLimitScope(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static RateLimitScope? tryParse(String? value) {
    for (final item in RateLimitScope.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// integration_token_scope — 07 §6.1.1 (CHECK). Поля: integration_tokens.scope.
/// Источник: ядро §17.3.
enum IntegrationTokenScope {
  onecInbound('onec_inbound');

  const IntegrationTokenScope(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static IntegrationTokenScope? tryParse(String? value) {
    for (final item in IntegrationTokenScope.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// integration_token_source — 07 §6.1.1 (CHECK). Поля: integration_tokens.source.
/// Источник: ядро §18.2 п.4.
enum IntegrationTokenSource {
  operatorScript('operator_script');

  const IntegrationTokenSource(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static IntegrationTokenSource? tryParse(String? value) {
    for (final item in IntegrationTokenSource.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// integration_token_revoke_reason — 07 §6.1.1 (CHECK). Поля: integration_tokens.revoke_reason.
/// Источник: ядро §18.2 п.4.
enum IntegrationTokenRevokeReason {
  rotated('rotated'),
  incident('incident'),
  disabled('disabled'),
  expired('expired');

  const IntegrationTokenRevokeReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static IntegrationTokenRevokeReason? tryParse(String? value) {
    for (final item in IntegrationTokenRevokeReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// receivable_document_kind — 07 §6.1.1 (CHECK). Поля: receivable_documents.kind.
/// Источник: ядро §19.2.
enum ReceivableDocumentKind {
  invoice('invoice'),
  payment('payment'),
  returnValue('return'),
  discount('discount'),
  adjustment('adjustment');

  const ReceivableDocumentKind(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReceivableDocumentKind? tryParse(String? value) {
    for (final item in ReceivableDocumentKind.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// receivable_document_status — 07 §6.1.1 (CHECK). Поля: receivable_documents.status.
/// Источник: ядро §19.2 (DEBT-003).
enum ReceivableDocumentStatus {
  posted('posted'),
  notPosted('not_posted'),
  due('due');

  const ReceivableDocumentStatus(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReceivableDocumentStatus? tryParse(String? value) {
    for (final item in ReceivableDocumentStatus.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// review_reason — 07 §6.1.1 (CHECK). Поля: payments.review_reason.
/// Источник: ядро §17.2 (D-21), v1.7 §22.2, v1.8 §23.4.
enum ReviewReason {
  amountMismatch('amount_mismatch'),
  unknownReference('unknown_reference'),
  noWebhook('no_webhook'),
  latePayment('late_payment');

  const ReviewReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReviewReason? tryParse(String? value) {
    for (final item in ReviewReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// cancel_reason_code — 07 §6.1.1 (CHECK). Поля: orders.cancel_reason_code.
/// Источник: ядро v1.7 §22.9; DTO reasonCode 08 §4.8.4.
enum CancelReasonCode {
  customerRefused('customer_refused'),
  duplicate('duplicate'),
  error('error'),
  other('other');

  const CancelReasonCode(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CancelReasonCode? tryParse(String? value) {
    for (final item in CancelReasonCode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// refund_intent — 07 §6.1.1 (CHECK). Поля: orders.refund_intent.
/// Источник: ядро v1.7 §22.9; DTO refundIntent 08 §4.8.4.
enum RefundIntent {
  none('none'),
  refund('refund'),
  advance('advance');

  const RefundIntent(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static RefundIntent? tryParse(String? value) {
    for (final item in RefundIntent.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// order_created_via — 07 §6.1.1 (CHECK). Поля: orders.created_via.
/// Источник: ядро v1.9 §24.2.
enum OrderCreatedVia {
  staff('staff'),
  customer('customer');

  const OrderCreatedVia(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OrderCreatedVia? tryParse(String? value) {
    for (final item in OrderCreatedVia.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// qr_provider_mode — 07 §6.1.1 (CHECK). Поля: payments.qr_provider.
/// Источник: ядро v1.9 §24.4.
enum QrProviderMode {
  none('none'),
  onec('onec'),
  bakai('bakai');

  const QrProviderMode(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static QrProviderMode? tryParse(String? value) {
    for (final item in QrProviderMode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// return_onec_result — 07 §6.1.1 (CHECK). Поля: return_requests.onec_result.
/// Источник: R7 §6.
enum ReturnOnecResult {
  moneyRefunded('money_refunded'),
  offsetAgainstDebt('offset_against_debt'),
  pending('pending');

  const ReturnOnecResult(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReturnOnecResult? tryParse(String? value) {
    for (final item in ReturnOnecResult.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// return_approval_reason — 07 §6.1.1 (CHECK). Поля: return_requests.approval_reason.
/// Источник: ядро §19.2.
enum ReturnApprovalReason {
  returnThresholdExceeded('return_threshold_exceeded');

  const ReturnApprovalReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ReturnApprovalReason? tryParse(String? value) {
    for (final item in ReturnApprovalReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// notification_severity — 07 §6.1.1 (CHECK). Поля: notifications.severity.
/// Источник: проектное.
enum NotificationSeverity {
  info('info'),
  warning('warning'),
  error('error');

  const NotificationSeverity(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static NotificationSeverity? tryParse(String? value) {
    for (final item in NotificationSeverity.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sync_error_code — 07 §6.1.1 (CHECK). Поля: sync_errors.error_code, onec_outbox.last_error_code, sync_node_state.last_error_code.
/// Источник: 08 §2.4 абзац «Коды журнала синхронизации» (владелец, порядок); 07 §6.1.1 (CHECK); ядро §17.4, §18.2 п.10; перечень в API — 08 §2.4 (отдельный абзац).
enum SyncErrorCode {
  duplicateSuspected('DUPLICATE_SUSPECTED'),
  outboxUnconfirmed('OUTBOX_UNCONFIRMED'),
  barcodeConflict('BARCODE_CONFLICT'),
  paymentDocVoided('PAYMENT_DOC_VOIDED'),
  orderMatchAmbiguous('ORDER_MATCH_AMBIGUOUS'),
  noWriteChannel('NO_WRITE_CHANNEL'),
  qrPaidAfterVoid('QR_PAID_AFTER_VOID'),
  notFoundLocal('NOT_FOUND_LOCAL'),
  validation('VALIDATION'),
  onecRejected('ONEC_REJECTED'),
  onecUnavailable('ONEC_UNAVAILABLE'),
  imageDownload('IMAGE_DOWNLOAD'),
  hashMismatch('HASH_MISMATCH'),
  countMismatch('COUNT_MISMATCH'),
  other('OTHER');

  const SyncErrorCode(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SyncErrorCode? tryParse(String? value) {
    for (final item in SyncErrorCode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sync_error_severity — 07 §6.1.1 (CHECK). Поля: sync_errors.severity.
/// Источник: проектное.
enum SyncErrorSeverity {
  warning('warning'),
  error('error');

  const SyncErrorSeverity(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SyncErrorSeverity? tryParse(String? value) {
    for (final item in SyncErrorSeverity.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// outbox_operation — 07 §6.1.1 (CHECK). Поля: onec_outbox.operation.
/// Источник: D-28, ядро v1.7 §22.1.
/// Не используются: update_status.
enum OutboxOperation {
  create('create'),
  cancel('cancel');

  const OutboxOperation(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static OutboxOperation? tryParse(String? value) {
    for (final item in OutboxOperation.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// audit_result — 07 §6.1.1 (CHECK). Поля: audit_logs.result.
/// Источник: D-36.
enum AuditResult {
  ok('ok'),
  denied('denied'),
  error('error');

  const AuditResult(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static AuditResult? tryParse(String? value) {
    for (final item in AuditResult.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// audit_severity — 07 §6.1.1 (CHECK). Поля: audit_logs.severity.
/// Источник: D-36.
enum AuditSeverity {
  info('info'),
  warning('warning'),
  critical('critical');

  const AuditSeverity(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static AuditSeverity? tryParse(String? value) {
    for (final item in AuditSeverity.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// setting_value_type — 07 §6.1.1 (CHECK). Поля: app_settings.value_type.
/// Источник: проектное.
enum SettingValueType {
  boolean('boolean'),
  integer('integer'),
  string('string'),
  json('json'),
  duration('duration'),
  money('money'),
  percent('percent');

  const SettingValueType(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SettingValueType? tryParse(String? value) {
    for (final item in SettingValueType.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// customer_stock_display — 07 §6.1.1 (CHECK). Поля: app_settings.customer_stock_display.
/// Источник: ядро v1.9 §24.2.
enum CustomerStockDisplay {
  status('status'),
  quantity('quantity');

  const CustomerStockDisplay(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CustomerStockDisplay? tryParse(String? value) {
    for (final item in CustomerStockDisplay.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// print_paper — 07 §6.1.1 (CHECK). Поля: print_jobs.paper.
/// Источник: D-27.
enum PrintPaper {
  a4('a4'),
  thermal80('thermal80');

  const PrintPaper(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static PrintPaper? tryParse(String? value) {
    for (final item in PrintPaper.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sms_template_key — 07 §6.1.1 (CHECK). Поля: sms_outbox.template_key.
/// Источник: D-11.
enum SmsTemplateKey {
  otpLogin('otp_login'),
  otpStepUp('otp_step_up'),
  otpPhoneChange('otp_phone_change'),
  otpCustomerLink('otp_customer_link');

  const SmsTemplateKey(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SmsTemplateKey? tryParse(String? value) {
    for (final item in SmsTemplateKey.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// sms_provider — 07 §6.1.1 (CHECK). Поля: sms_outbox.provider.
/// Источник: D-11, ядро §17.3.
enum SmsProvider {
  smspro('smspro'),
  fake('fake');

  const SmsProvider(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static SmsProvider? tryParse(String? value) {
    for (final item in SmsProvider.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

// ===== 08 §2.4, §3.8 — перечни контракта API =====

/// credit_reason — 08 §3.8 paymentChecks.creditReason (enum CreditReason), §5.5; ядро §22.4 в редакции §23 п.5; владелец правила — 10 PAY-031.
/// Не используются: not_identified, onec_inbound_mode, not_allowed, no_data, receivables_stale, onec_unavailable.
enum CreditReason {
  forbiddenRole('forbidden_role'),
  creditNotAllowed('credit_not_allowed'),
  overdue('overdue'),
  limitExceeded('limit_exceeded'),
  staleSnapshot('stale_snapshot');

  const CreditReason(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static CreditReason? tryParse(String? value) {
    for (final item in CreditReason.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// warning_code — 08 §2.4 «Предупреждения (не ошибки)» — warnings[].code успешного ответа; не входят в Problem.code.
enum WarningCode {
  staleData('STALE_DATA'),
  qrUnavailable('QR_UNAVAILABLE'),
  paymentAmountMismatch('PAYMENT_AMOUNT_MISMATCH');

  const WarningCode(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static WarningCode? tryParse(String? value) {
    for (final item in WarningCode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// problem_resource — 08 §2.4 ORDER_STATE_INVALID — поле resource; 08 §8 Problem.resource.
enum ProblemResource {
  order('order'),
  cart('cart'),
  returnRequest('return_request'),
  outboxItem('outbox_item');

  const ProblemResource(this.value);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ProblemResource? tryParse(String? value) {
    for (final item in ProblemResource.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

// ===== 08 §2.4 — коды ошибок Problem.code =====

/// problem_code — Problem.code, 08 §2.4 (владелец словаря, ядро §18.1).
/// Клиент ветвится только по code и HTTP-статусу; неизвестный code — как INTERNAL того же класса.
enum ProblemCode {
  validationFailed('VALIDATION_FAILED', [400, 422]),
  otpInvalid('OTP_INVALID', [422]),
  otpExpired('OTP_EXPIRED', [422]),
  otpLocked('OTP_LOCKED', [423]),
  otpRateLimited('OTP_RATE_LIMITED', [429]),
  smsProviderError('SMS_PROVIDER_ERROR', [503]),
  registrationTokenInvalid('REGISTRATION_TOKEN_INVALID', [401]),
  phoneAlreadyRegistered('PHONE_ALREADY_REGISTERED', [409]),
  unauthenticated('UNAUTHENTICATED', [401]),
  tokenStale('TOKEN_STALE', [401]),
  sessionRevoked('SESSION_REVOKED', [401]),
  deviceMismatch('DEVICE_MISMATCH', [409]),
  stepUpRequired('STEP_UP_REQUIRED', [403]),
  forbidden('FORBIDDEN', [403]),
  versionConflict('VERSION_CONFLICT', [409]),
  idempotencyKeyReused('IDEMPOTENCY_KEY_REUSED', [422]),
  idempotencyInProgress('IDEMPOTENCY_IN_PROGRESS', [409]),
  priceChanged('PRICE_CHANGED', [422]),
  stockInsufficient('STOCK_INSUFFICIENT', [422]),
  variantUnavailable('VARIANT_UNAVAILABLE', [422]),
  qtyNotMultiple('QTY_NOT_MULTIPLE', [422]),
  qtyBelowMin('QTY_BELOW_MIN', [422]),
  discountLimitExceeded('DISCOUNT_LIMIT_EXCEEDED', [422]),
  creditBlocked('CREDIT_BLOCKED', [422]),
  creditLimitExceeded('CREDIT_LIMIT_EXCEEDED', [422]),
  receivablesStale('RECEIVABLES_STALE', [422]),
  onecUnavailable('ONEC_UNAVAILABLE', [503]),
  onecRejected('ONEC_REJECTED', [422]),
  orderStateInvalid('ORDER_STATE_INVALID', [409]),
  paymentStateInvalid('PAYMENT_STATE_INVALID', [409]),
  customerLinkConflict('CUSTOMER_LINK_CONFLICT', [409]),
  customerDuplicateSuspected('CUSTOMER_DUPLICATE_SUSPECTED', [409]),
  syncAlreadyRunning('SYNC_ALREADY_RUNNING', [409]),
  notFound('NOT_FOUND', [404]),
  rateLimited('RATE_LIMITED', [429]),
  internal('INTERNAL', [500]),
  appUpdateRequired('APP_UPDATE_REQUIRED', [426]),
  payloadTooLarge('PAYLOAD_TOO_LARGE', [413]),
  unsupportedMediaType('UNSUPPORTED_MEDIA_TYPE', [415]),
  methodNotAllowed('METHOD_NOT_ALLOWED', [405]),
  customerNotIdentified('CUSTOMER_NOT_IDENTIFIED', [422]),
  cartEmpty('CART_EMPTY', [422]),
  pinInvalid('PIN_INVALID', [401]),
  pinLocked('PIN_LOCKED', [423]),
  unlockRequired('UNLOCK_REQUIRED', [401]),
  returnQtyExceeded('RETURN_QTY_EXCEEDED', [422]),
  webhookSignatureInvalid('WEBHOOK_SIGNATURE_INVALID', [401]),
  qrUnavailable('QR_UNAVAILABLE', [503]),
  consentRequired('CONSENT_REQUIRED', [422]),
  appReadOnly('APP_READ_ONLY', [503]);

  const ProblemCode(this.value, this.httpStatuses);

  /// Значение в API и БД — ровно как в документе-владельце.
  final String value;

  /// Допустимые HTTP-статусы ответа с этим кодом (08 §2.4).
  final List<int> httpStatuses;

  /// Значение по строке; `null` — неизвестное значение (совместимость вперёд).
  static ProblemCode? tryParse(String? value) {
    for (final item in ProblemCode.values) {
      if (item.value == value) return item;
    }
    return null;
  }
}

/// Реестр типов PostgreSQL: имя типа → значения в порядке CREATE TYPE (07 §6.1).
const Map<String, List<String>> dbEnumValues = {
  'user_kind': ['staff', 'customer'],
  'user_status': ['pending', 'pending_activation', 'active', 'blocked', 'deleted'],
  'role_code': ['seller', 'cashier', 'senior_seller', 'admin', 'owner', 'customer', 'integration'],
  'customer_link_status': ['proposed', 'confirmed', 'rejected', 'conflict'],
  'cart_status': ['active', 'parked', 'converted', 'cleared'],
  'order_status': ['draft', 'submitting', 'submit_failed', 'pending_approval', 'awaiting_payment', 'approved', 'awaiting_shipment', 'shipped', 'partially_returned', 'closed', 'cancelled'],
  'delivery_method': ['pickup', 'delivery'],
  'receiver_kind': ['customer', 'other_person'],
  'payment_method': ['cash', 'qr_bakai', 'credit'],
  'payment_status': ['initiated', 'cash_pending', 'qr_pending', 'qr_shown', 'qr_expired', 'manual_confirm', 'credit', 'received', 'voided', 'refunded'],
  'return_request_status': ['draft', 'submitted', 'accepted', 'rejected', 'completed'],
  'transaction_kind': ['order_created', 'order_cancelled', 'payment_received', 'payment_voided', 'refund', 'discount_override', 'credit_sale_approved', 'manual_qr_confirm', 'return_requested'],
  'sync_entity': ['categories', 'products', 'variants', 'attributes', 'units', 'barcodes', 'images', 'warehouses', 'stock', 'prices', 'customers', 'receivables', 'sales_history', 'order_status', 'discounts', 'payment_docs', 'return_docs'],
  'sync_mode': ['full', 'incremental', 'manual', 'reconcile'],
  'sync_run_status': ['queued', 'running', 'success', 'partial', 'failed'],
  'outbox_status': ['pending', 'sending', 'sent', 'confirmed', 'failed', 'dead', 'cancelled'],
  'notification_kind': ['sync_error', 'order_status', 'cart_price_changed', 'cart_stock_changed', 'credit_blocked', 'system', 'payment_status', 'return_status'],
  'invitation_status': ['pending', 'accepted', 'revoked', 'expired'],
  'device_platform': ['android', 'ios', 'windows'],
  'session_kind': ['standard', 'biometric'],
  'step_up_method': ['pin', 'biometric', 'otp'],
  'otp_purpose': ['login_or_register', 'step_up', 'phone_change_old', 'phone_change_new', 'customer_link'],
  'otp_status': ['sent', 'verified', 'expired', 'locked', 'failed_delivery', 'superseded'],
  'consent_kind': ['personal_data', 'sms', 'biometrics_device', 'activity_sphere', 'face_scan'],
  'attribute_value_type': ['text', 'number', 'boolean', 'list'],
  'barcode_type': ['EAN13', 'EAN8', 'UPC', 'CODE128', 'CODE39', 'QR', 'other'],
  'image_status': ['pending', 'downloading', 'ready', 'failed', 'missing_source'],
  'customer_source': ['onec', 'pos'],
  'customer_type': ['individual', 'entrepreneur', 'legal'],
  'customer_onec_status': ['n_a', 'pending', 'confirmed', 'rejected', 'duplicate'],
  'contact_kind': ['phone', 'address', 'email', 'other'],
  'link_match_method': ['phone', 'manual_admin', 'onec_created'],
  'discount_source': ['onec', 'pos'],
  'discount_kind': ['percent', 'fixed_amount', 'price_list'],
  'status_change_source': ['pos_user', 'pos_system', 'onec_sync', 'onec_response'],
  'transaction_source': ['pos', 'onec'],
  'return_reason': ['defect', 'wrong_item', 'not_suitable', 'surplus', 'seller_error', 'other'],
  'sync_trigger': ['schedule', 'manual', 'retry', 'dependency'],
  'outbox_aggregate': ['order', 'payment', 'customer', 'return_request'],
  'idempotency_status': ['in_progress', 'completed'],
  'audit_level': ['app', 'db'],
  'print_document_kind': ['invoice', 'waybill', 'receipt'],
  'print_job_status': ['queued', 'ready', 'failed', 'unavailable_onec'],
  'sms_status': ['queued', 'sent', 'delivered', 'failed', 'expired'],
  'onec_sync_state': ['unknown', 'pending', 'linked', 'missing', 'ambiguous'],
};

/// Реестр CHECK-перечней: поле таблицы → допустимые значения (07 §6.1.1).
const Map<String, List<String>> checkListValues = {
  'user_profiles.locale': ['ru', 'ky', 'en'],
  'user_invitations.role': ['seller', 'cashier', 'senior_seller', 'admin', 'owner'],
  'sessions.revoke_reason': ['logout', 'logout_all', 'reuse_detected', 'admin', 'phone_changed', 'role_changed', 'expired', 'device_revoked', 'blocked', 'session_limit', 'device_mismatch', 'biometric_invalidated', 'refresh_replay'],
  'token_denylist.token_kind': ['access', 'registration', 'step_up'],
  'token_denylist.reason': ['logout', 'logout_all', 'role_changed', 'blocked', 'used', 'revoked'],
  'rate_limit_counters.scope': ['otp_phone_15m', 'otp_phone_24h', 'otp_ip_1h', 'otp_device_24h', 'login_ip_1h', 'step_up_user_1h', 'webhook_ip_1m', 'otp_ip_10m', 'otp_ip_24h', 'otp_device_10m', 'otp_global_1m', 'otp_verify_ip_10m', 'pin_user_device_10m', 'admin_user_1m'],
  'integration_tokens.scope': ['onec_inbound'],
  'integration_tokens.source': ['operator_script'],
  'integration_tokens.revoke_reason': ['rotated', 'incident', 'disabled', 'expired'],
  'receivable_documents.kind': ['invoice', 'payment', 'return', 'discount', 'adjustment'],
  'receivable_documents.status': ['posted', 'not_posted', 'due'],
  'payments.review_reason': ['amount_mismatch', 'unknown_reference', 'no_webhook', 'late_payment'],
  'orders.cancel_reason_code': ['customer_refused', 'duplicate', 'error', 'other'],
  'orders.refund_intent': ['none', 'refund', 'advance'],
  'orders.created_via': ['staff', 'customer'],
  'payments.qr_provider': ['none', 'onec', 'bakai'],
  'return_requests.onec_result': ['money_refunded', 'offset_against_debt', 'pending'],
  'return_requests.approval_reason': ['return_threshold_exceeded'],
  'notifications.severity': ['info', 'warning', 'error'],
  'sync_errors.error_code': ['DUPLICATE_SUSPECTED', 'OUTBOX_UNCONFIRMED', 'BARCODE_CONFLICT', 'PAYMENT_DOC_VOIDED', 'ORDER_MATCH_AMBIGUOUS', 'NO_WRITE_CHANNEL', 'QR_PAID_AFTER_VOID', 'NOT_FOUND_LOCAL', 'VALIDATION', 'ONEC_REJECTED', 'ONEC_UNAVAILABLE', 'IMAGE_DOWNLOAD', 'HASH_MISMATCH', 'COUNT_MISMATCH', 'OTHER'],
  'onec_outbox.last_error_code': ['DUPLICATE_SUSPECTED', 'OUTBOX_UNCONFIRMED', 'BARCODE_CONFLICT', 'PAYMENT_DOC_VOIDED', 'ORDER_MATCH_AMBIGUOUS', 'NO_WRITE_CHANNEL', 'QR_PAID_AFTER_VOID', 'NOT_FOUND_LOCAL', 'VALIDATION', 'ONEC_REJECTED', 'ONEC_UNAVAILABLE', 'IMAGE_DOWNLOAD', 'HASH_MISMATCH', 'COUNT_MISMATCH', 'OTHER'],
  'sync_node_state.last_error_code': ['DUPLICATE_SUSPECTED', 'OUTBOX_UNCONFIRMED', 'BARCODE_CONFLICT', 'PAYMENT_DOC_VOIDED', 'ORDER_MATCH_AMBIGUOUS', 'NO_WRITE_CHANNEL', 'QR_PAID_AFTER_VOID', 'NOT_FOUND_LOCAL', 'VALIDATION', 'ONEC_REJECTED', 'ONEC_UNAVAILABLE', 'IMAGE_DOWNLOAD', 'HASH_MISMATCH', 'COUNT_MISMATCH', 'OTHER'],
  'sync_errors.severity': ['warning', 'error'],
  'onec_outbox.operation': ['create', 'cancel'],
  'audit_logs.result': ['ok', 'denied', 'error'],
  'audit_logs.severity': ['info', 'warning', 'critical'],
  'app_settings.value_type': ['boolean', 'integer', 'string', 'json', 'duration', 'money', 'percent'],
  'app_settings.customer_stock_display': ['status', 'quantity'],
  'print_jobs.paper': ['a4', 'thermal80'],
  'sms_outbox.template_key': ['otp_login', 'otp_step_up', 'otp_phone_change', 'otp_customer_link'],
  'sms_outbox.provider': ['smspro', 'fake'],
};
