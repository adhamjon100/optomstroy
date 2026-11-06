// Оформление заявки с планшета магазина — SCR-52 «Телефон» / «Код» и SCR-53 «Заявка отправлена» (02 ч. F SCR-52,
// SCR-53; 04 FLOW-044.S3–S7, A1–A4; 08 §4.7.7 «Предпросмотр на планшете», §4.25.1–§4.25.3; P-002 §8.4 п. 4,
// §8.5 п. 3, 5, 9, 10; ADR-115 п. 16; 13 TAB-2-04). Чистый Dart (FL-01).
//
// Данные покупателя — только в памяти (02 ч. F, правило 3; 10 KIOSK-021; 11 PRIV-033): номер, `challengeId`, код,
// ключ идемпотентности, `previewToken` и номер заявки не пишутся в адрес, drift, защищённое хранилище, журналы и
// отчёты об ошибках. Поэтому `toString` сущностей ниже их не раскрывает.
//
// Реакции экрана на ответы сервера — чистые функции [kioskOtpOutcomeOf] и [kioskOrderOutcomeOf] (таблица ответов
// 02 SCR-52.4): тексты нейтральные — без причины 1С, сумм, клиента и признака найденной карточки (10 KIOSK-016;
// 11 SEC-141).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Версия текста информирования `kiosk_order_notice`, показанного над «Получить код» (`contracts/legal/notices_ru.md`;
/// ARB `kiosk_notice_short` / `kiosk_notice_full`; 11 PRIV-032; ADR-115 п. 16). Уходит в `POST /kiosk/order-otp`
/// (`noticeVersion`). Новая версия текста — новый раздел файла, новые строки 02 §7 и новое значение здесь
/// (тест паритета `test/features/kiosk/notice_text_parity_test.dart`).
const String kioskNoticeVersion = '2026-11-04';

/// Числа правил оформления (P-002 §8.5 п. 5, п. 10; 08 §4.25.1–§4.25.3; 02 SCR-52.4).
abstract final class KioskCheckoutRules {
  /// Длина номера после «+996» (03 §9.4).
  static const int phoneLength = 9;

  /// Длина кода из SMS (03 §9.5).
  static const int codeLength = 6;

  /// Повтор кода на тот же номер раньше этого срока — `429 OTP_RATE_LIMITED` с `retryAfter`: на экране таймер, а не
  /// ошибка (09 §5.4; P-002 §8.5 п. 5). Больший `retryAfter` — лимит номера: «Обратитесь к продавцу».
  static const Duration resendCooldown = Duration(seconds: 60);

  /// Окно повтора того же верного кода после отказа по остатку (P-002 §8.5 п. 3; 04 FLOW-044.A3).
  static const Duration replayWindow = Duration(seconds: 60);

  /// Восстановление по ключу после обрыва — заявка этого планшета за 15 мин (08 §4.25.3); дольше без связи — ошибка.
  static const Duration recoveryWindow = Duration(minutes: 15);

  /// Ожидание у `409 IDEMPOTENCY_IN_PROGRESS` без `retryAfter` (сервер шлёт 2 с — P-002 §8.5 п. 10).
  static const Duration inProgressWait = Duration(seconds: 2);

  /// Пауза перед повтором той же попытки тем же ключом после обрыва [ТИПОВО].
  static const Duration networkRetryDelay = Duration(seconds: 2);

  /// Шаг опроса `GET /kiosk/orders?idempotencyKey=`, пока нет связи [ТИПОВО].
  static const Duration recoveryPoll = Duration(seconds: 5);
}

/// Шаг SCR-52 (`/kiosk/checkout?step=phone|code`, `visual/navigation.md` §3).
enum KioskCheckoutStep {
  phone('phone'),
  code('code');

  const KioskCheckoutStep(this.value);

  /// Значение параметра `step` адреса.
  final String value;

  /// Шаг по параметру адреса; неизвестное значение или его отсутствие — «Телефон».
  static KioskCheckoutStep parse(String? value) => value == code.value ? code : phone;
}

/// Серверная корзина планшета, по которой оформляется заявка (`cartId`, `rowVersion` — 08 §4.7.7).
final class KioskCartRef {
  const KioskCartRef({required this.cartId, required this.rowVersion});

  final String cartId;
  final int rowVersion;

  @override
  bool operator ==(Object other) => other is KioskCartRef && other.cartId == cartId && other.rowVersion == rowVersion;

  @override
  int get hashCode => Object.hash(cartId, rowVersion);

  @override
  String toString() => 'KioskCartRef(rowVersion: $rowVersion)';
}

/// Корзина планшета для оформления (порт; реализацию — корзину фичи cart — подставляет корень
/// `app/router/shells/kiosk_mode_bindings.dart`).
abstract interface class KioskCheckoutCart {
  /// Изменения корзины отправлены; текущая серверная корзина на экране. `null` — корзины нет или она пуста.
  Future<KioskCartRef?> current();

  /// Перечитать корзину с сервера (`GET /cart`): после отказа по остатку строки отмечаются по `warnings[]` сервера
  /// (02 UI-51-018); строки отказа без пометки сервера отмечает SCR-52 (`kioskCartMarkStockChangedProvider`).
  Future<void> refresh();
}

/// Состав и сумма шага «Телефон» из `POST /cart/checkout-preview` (02 UI-52-002) и токен для заявки.
final class KioskPreview {
  const KioskPreview({
    required this.cartId,
    required this.cartRowVersion,
    required this.positions,
    this.subtotal,
    this.total,
    this.previewToken,
    this.stockChanged = false,
    this.stockConflicts = const <KioskStockConflict>[],
  });

  final String cartId;

  /// Версия корзины, которую подписал токен (уходит в `POST /kiosk/orders`).
  final int cartRowVersion;

  /// «Товаров ({count})» — число строк предпросмотра.
  final int positions;
  final Money? subtotal;

  /// «Итого» — к оплате по обычным ценам магазина (`totalToPay`, иначе `total`).
  final Money? total;

  /// Непрозрачный токен предпросмотра (5 мин); только в памяти.
  final String? previewToken;

  /// `ok=false` с конфликтом остатка, доступности или кратности: заявка не пройдёт — возврат к корзине (FLOW-044.A3).
  final bool stockChanged;

  /// Строки этих конфликтов (`variantId`, `kind`, `stockLevel`) — для отметки строк drawer.
  final List<KioskStockConflict> stockConflicts;

  @override
  String toString() => 'KioskPreview(positions: $positions, stockChanged: $stockChanged)';
}

/// `202 POST /kiosk/order-otp {challengeId, resendAfterSec}` — одинаков для любого номера (08 §4.25.1).
final class KioskOtpChallenge {
  const KioskOtpChallenge({required this.challengeId, required this.resendAfter});

  final String challengeId;

  /// Когда можно запросить код повторно (`resendAfterSec`).
  final Duration resendAfter;

  @override
  String toString() => 'KioskOtpChallenge(resendAfter: ${resendAfter.inSeconds} s)';
}

/// Тело `POST /kiosk/orders` (`KioskOrdersCreateRequest`, 08 §4.25.2): только идентификаторы и код — клиента,
/// получателя, оплаты, доставки, скидки, цен, итогов и `noticeVersion` в теле нет (иначе `400 forbidden_field`).
/// Для повтора той же попытки тем же ключом тело не меняется (P-002 §8.5 п. 10).
final class KioskOrderRequest {
  const KioskOrderRequest({
    required this.challengeId,
    required this.code,
    required this.cartId,
    required this.cartRowVersion,
    required this.previewToken,
  });

  final String challengeId;

  /// Код из SMS — 6 цифр; не логируется.
  final String code;
  final String cartId;
  final int cartRowVersion;
  final String previewToken;

  @override
  String toString() => 'KioskOrderRequest(rowVersion: $cartRowVersion)';
}

/// Ответ о заявке планшету — только номер (`KioskOrderAccepted`, 08 §3.17; 10 KIOSK-016).
final class KioskOrderAccepted {
  const KioskOrderAccepted(this.publicNumber);

  /// «POS-2026-000123».
  final String publicNumber;

  @override
  bool operator ==(Object other) => other is KioskOrderAccepted && other.publicNumber == publicNumber;

  @override
  int get hashCode => publicNumber.hashCode;

  @override
  String toString() => 'KioskOrderAccepted(…)';
}

/// Отказ, который показывает каркас режима (`KioskStateView`, 02 SCR-51.7), а не шаг оформления: `426`,
/// `401` сессии и `KIOSK_REVOKED`, `403 KIOSK_DISABLED` / `KIOSK_NETWORK_DENIED` / `kiosk_warehouse_unavailable`.
bool kioskShellHandles(Failure f) => switch (f) {
  AppUpdateRequiredFailure() => true,
  AuthFailure(:final AuthReason reason) => switch (reason) {
    AuthReason.unauthenticated ||
    AuthReason.tokenStale ||
    AuthReason.sessionRevoked ||
    AuthReason.deviceMismatch => true,
    _ => false,
  },
  PermissionFailure(:final String? serverReason) => serverReason == kioskWarehouseUnavailableReason,
  ServerFailure(:final ProblemCode? problemCode) =>
    problemCode == ProblemCode.kioskRevoked ||
        problemCode == ProblemCode.kioskDisabled ||
        problemCode == ProblemCode.kioskNetworkDenied,
  _ => false,
};

/// `403 FORBIDDEN` `reason` — склад планшета не задан или неактивен (08 §4.25; ADR-115 п. 23).
const String kioskWarehouseUnavailableReason = 'kiosk_warehouse_unavailable';

/// Реакция шага «Телефон» на отказ `POST /kiosk/order-otp` (02 SCR-52.4).
sealed class KioskOtpOutcome {
  const KioskOtpOutcome();
}

/// `429 OTP_RATE_LIMITED` на тот же номер раньше 60 с — шаг «Код» с таймером, без ошибки.
final class KioskOtpCooldown extends KioskOtpOutcome {
  const KioskOtpCooldown(this.retryAfter);

  final Duration retryAfter;
}

/// `429 KIOSK_RATE_LIMITED`, лимиты номера, `423 OTP_LOCKED` — «Не удаётся отправить код. Обратитесь к продавцу».
final class KioskOtpCallSeller extends KioskOtpOutcome {
  const KioskOtpCallSeller();
}

/// `422 CART_EMPTY` — переход на `/kiosk`.
final class KioskOtpCartEmpty extends KioskOtpOutcome {
  const KioskOtpCartEmpty();
}

/// Нет связи — текста ошибки нет: баннер «Нет связи…» и недоступная кнопка.
final class KioskOtpOffline extends KioskOtpOutcome {
  const KioskOtpOffline();
}

/// Состояние планшета показывает каркас ([kioskShellHandles]).
final class KioskOtpShell extends KioskOtpOutcome {
  const KioskOtpShell();
}

/// `422 VALIDATION_FAILED` (неизвестная версия текста) и прочие отказы — «Заявку не удалось отправить…».
final class KioskOtpFailed extends KioskOtpOutcome {
  const KioskOtpFailed();
}

/// Отказ `POST /kiosk/order-otp` → реакция экрана.
KioskOtpOutcome kioskOtpOutcomeOf(Failure f) {
  if (kioskShellHandles(f)) return const KioskOtpShell();
  return switch (f) {
    AuthFailure(reason: AuthReason.otpRateLimited, :final Duration? retryAfter)
        when retryAfter == null || retryAfter <= KioskCheckoutRules.resendCooldown =>
      KioskOtpCooldown(retryAfter ?? KioskCheckoutRules.resendCooldown),
    AuthFailure(reason: AuthReason.otpRateLimited || AuthReason.otpLocked) => const KioskOtpCallSeller(),
    ServerFailure(:final ProblemCode? problemCode)
        when problemCode == ProblemCode.kioskRateLimited || problemCode == ProblemCode.rateLimited =>
      const KioskOtpCallSeller(),
    ServerFailure(problemCode: ProblemCode.cartEmpty) => const KioskOtpCartEmpty(),
    NetworkFailure(kind: NetworkFailureKind.offline) => const KioskOtpOffline(),
    _ => const KioskOtpFailed(),
  };
}

/// Реакция «Отправить заявку» на отказ `POST /kiosk/orders` (02 SCR-52.4, таблица ответов).
sealed class KioskOrderOutcome {
  const KioskOrderOutcome();
}

/// `422 OTP_INVALID {attemptsLeft}` — поле кода очищено, «Неверный код. Осталось попыток: {n}».
final class KioskOrderCodeInvalid extends KioskOrderOutcome {
  const KioskOrderCodeInvalid(this.attemptsLeft);

  final int? attemptsLeft;
}

/// `422 OTP_EXPIRED` и `404 NOT_FOUND` — «Код больше не действует. Получите новый код».
final class KioskOrderCodeExpired extends KioskOrderOutcome {
  const KioskOrderCodeExpired();
}

/// `423 OTP_LOCKED` — поле кода недоступно, «Не удаётся отправить код. Обратитесь к продавцу».
final class KioskOrderCodeLocked extends KioskOrderOutcome {
  const KioskOrderCodeLocked();
}

/// Строка `conflicts[]` отказа планшету: только `variantId`, `kind`, `stockLevel` (08 §2.4 «Коды и отказы планшета
/// магазина» п. 3). Та же форма записи, что `KioskCartStockConflict` фичи cart (типы записей совпадают по форме).
typedef KioskStockConflict = ({String variantId, String kind, String? stockLevel});

/// `conflicts[]` из тела отказа ([details] — `ConflictFailure.details`); строки без `variantId` или `kind` пропускаются.
List<KioskStockConflict> kioskStockConflictsOf(Map<String, Object?> details) {
  final Object? list = details['conflicts'];
  if (list is! List) return const <KioskStockConflict>[];
  return <KioskStockConflict>[
    for (final Object? item in list)
      if (item is Map && item['variantId'] is String && item['kind'] is String)
        (
          variantId: item['variantId'] as String,
          kind: item['kind'] as String,
          stockLevel: item['stockLevel'] is String ? item['stockLevel'] as String : null,
        ),
  ];
}

/// `409 VERSION_CONFLICT`, `422 STOCK_INSUFFICIENT` / `VARIANT_UNAVAILABLE` / `QTY_NOT_MULTIPLE` / `QTY_BELOW_MIN` —
/// возврат к корзине с отмеченными строками; потом — тот же код в окне 60 с (FLOW-044.A3). [conflicts] — строки отказа
/// из ответа: drawer отмечает их, даже если `GET /cart` их не пометил (02 UI-51-018).
final class KioskOrderStockChanged extends KioskOrderOutcome {
  const KioskOrderStockChanged([this.conflicts = const <KioskStockConflict>[]]);

  final List<KioskStockConflict> conflicts;
}

/// `422 PRICE_CHANGED` `reason` `preview_token_invalid` / `preview_cart_changed` — молча новый предпросмотр и одна
/// повторная отправка с новым ключом (P-002 §8.4 п. 4).
final class KioskOrderPreviewStale extends KioskOrderOutcome {
  const KioskOrderPreviewStale();
}

/// `409 IDEMPOTENCY_IN_PROGRESS {retryAfter}` — ждать и повторить ту же попытку тем же ключом.
final class KioskOrderInProgress extends KioskOrderOutcome {
  const KioskOrderInProgress(this.retryAfter);

  final Duration retryAfter;
}

/// Нет ответа (обрыв, таймаут 30 с, сервер недоступен) — повтор тем же ключом, затем восстановление по ключу.
final class KioskOrderNoAnswer extends KioskOrderOutcome {
  const KioskOrderNoAnswer();
}

/// Состояние планшета показывает каркас ([kioskShellHandles]).
final class KioskOrderShell extends KioskOrderOutcome {
  const KioskOrderShell();
}

/// `422 ONEC_REJECTED`, `422 IDEMPOTENCY_KEY_REUSED`, прочие `4xx` / `5xx` — «Заявку не удалось отправить.
/// Обратитесь к продавцу»; причина 1С на экран не выводится.
final class KioskOrderFailed extends KioskOrderOutcome {
  const KioskOrderFailed();
}

/// `reason` у `422 PRICE_CHANGED`, на которые планшет отвечает новым предпросмотром (`checkout.service.ts:574`, `:576`).
const Set<String> kioskPreviewStaleReasons = <String>{'preview_token_invalid', 'preview_cart_changed'};

/// Отказ `POST /kiosk/orders` → реакция экрана.
KioskOrderOutcome kioskOrderOutcomeOf(Failure f) {
  if (kioskShellHandles(f)) return const KioskOrderShell();
  return switch (f) {
    AuthFailure(reason: AuthReason.otpInvalid, :final int? attemptsLeft) => KioskOrderCodeInvalid(attemptsLeft),
    AuthFailure(reason: AuthReason.otpExpired) => const KioskOrderCodeExpired(),
    AuthFailure(reason: AuthReason.otpLocked) => const KioskOrderCodeLocked(),
    ServerFailure(problemCode: ProblemCode.notFound) => const KioskOrderCodeExpired(),
    ConflictFailure(kind: ConflictKind.priceChanged, :final String? reason)
        when kioskPreviewStaleReasons.contains(reason) =>
      const KioskOrderPreviewStale(),
    ConflictFailure(kind: ConflictKind.idempotencyInProgress, :final Duration? retryAfter) => KioskOrderInProgress(
      retryAfter ?? KioskCheckoutRules.inProgressWait,
    ),
    ConflictFailure(:final ConflictKind kind, :final Map<String, Object?> details)
        when kioskStockConflicts.contains(kind) =>
      KioskOrderStockChanged(kioskStockConflictsOf(details)),
    NetworkFailure() => const KioskOrderNoAnswer(),
    _ => const KioskOrderFailed(),
  };
}

/// Конфликты корзины, после которых покупатель исправляет количество в drawer (02 SCR-52.4; FLOW-044.A3).
const Set<ConflictKind> kioskStockConflicts = <ConflictKind>{
  ConflictKind.versionConflict,
  ConflictKind.stockInsufficient,
  ConflictKind.variantUnavailable,
  ConflictKind.qtyNotMultiple,
  ConflictKind.qtyBelowMin,
};
