// Публичный контракт фичи kiosk (06 §6.1, §6.2 «Размещение режима «Планшет магазина»» п. (3); FL-07): режим
// «Планшет магазина» — SCR-51 `/kiosk`, SCR-52 `/kiosk/checkout`, SCR-53 `/kiosk/done` (02 ч. F; P-002, ADR-115).
//
// Рёбра DAG фичи — `kiosk → catalog, cart, checkout` (06 §6.1; `scripts/check_layers.py`, `FEATURE_DAG`); фичу
// `kiosk` не импортирует ни одна фича. Тело витрины SCR-51 принадлежит фиче catalog (ADR-114 в варианте покупателя):
// экран режима получает построитель через порт [kioskCatalogBodyProvider], привязку делает композиционный корень
// (`app/router/shells/kiosk_mode_bindings.dart` → `appOverrides`, как SCR-50 — `customer_mode_bindings.dart`),
// в тестах — `overrideWithValue`.
//
// Закрепление планшета — порт `KioskLock` (`core/hardware/kiosk_lock.dart`; 06 §6.2 п. (3), (8); 13 TAB-2-09): экраны
// фичи получают его отсюда, а не из `core/hardware` (FL-02). Провайдер объявлен в core, потому что его читают и
// core-части режима (сессия планшета — снятие при `KIOSK_REVOKED`, заголовок `X-Kiosk-Lock` — ADR-115 п. 26), а core
// фичи не импортирует (FL-04). Реализацию платформы подставляет корень `app/di/overrides.dart`.
//
// Аварийный выход SCR-51 UI-51-017 (P-002 §8.9 п. 2; 08 §4.25.5; ADR-115 п. 12, п. 28; 13 TAB-2-10) — порт
// [KioskLifecycleRepository] (`POST /kiosk/exit`): реализация — `data/dio_kiosk_lifecycle_repository.dart`, привязка —
// `data/kiosk_bindings.dart` в корне; без привязки ([kioskLifecycleRepositoryProvider] = `null`) код проверяется только
// на устройстве.
//
// Оформление заявки SCR-52 / SCR-53 (08 §4.25.1–§4.25.3; 13 TAB-2-04) — порты [kioskRepositoryProvider]
// (`POST /kiosk/order-otp`, `POST /kiosk/orders`, `GET /kiosk/orders?idempotencyKey=`; реализация —
// `data/dio_kiosk_repository.dart`, привязка — `data/kiosk_bindings.dart`) и [kioskCheckoutCartProvider] (корзина
// фичи cart; привязка — корень `app/router/shells/kiosk_mode_bindings.dart`). Без привязки шаги оформления пусты, как
// витрина без [kioskCatalogBodyProvider].
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_repository.dart';

export 'package:optomstroy/core/hardware/kiosk_lock.dart'
    show KioskLock, KioskLockError, KioskLockStatus, NoKioskLock, kioskLockPolicy, kioskLockProvider;
export 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart' show KioskCartRef, KioskCheckoutCart;
export 'package:optomstroy/features/kiosk/domain/kiosk_repository.dart' show KioskRepository;

/// Параметры маршрута SCR-51 `/kiosk?c=` (только path/query, 06 §6.4; navigation.md §3).
///
/// `c` пишет сам экран заменой записи. Строка поиска — только в памяти экрана: в адрес не пишется и из адреса не
/// читается (02 ч. F, правило 3; PRIV-033; 01 GEN-254). Персональных данных в адресе нет (N-3).
@immutable
final class KioskCatalogArgs {
  const KioskCatalogArgs({this.categoryId});

  /// `c` — выбранная категория.
  final String? categoryId;

  @override
  bool operator ==(Object other) => other is KioskCatalogArgs && other.categoryId == categoryId;

  @override
  int get hashCode => categoryId.hashCode;

  @override
  String toString() => 'KioskCatalogArgs(c: $categoryId)';
}

/// Построитель тела витрины SCR-51.
typedef KioskCatalogBodyBuilder = Widget Function(BuildContext context, KioskCatalogArgs args);

/// Тело витрины SCR-51; `null` — корень не подключил каталог (экран режима показывает пустой фон, как SCR-50 без
/// [KioskCatalogBodyBuilder]).
final kioskCatalogBodyProvider = Provider<KioskCatalogBodyBuilder?>((ref) => null);

/// Итог `POST /kiosk/exit {code}` (08 §4.25.5).
sealed class KioskServerExitResult {
  const KioskServerExitResult();
}

/// `200` — код погашен, сессии планшета отозваны (`kiosk_revoked`); так же — повтор после потерянного `200`
/// (`401 KIOSK_REVOKED`).
final class KioskServerExitAccepted extends KioskServerExitResult {
  const KioskServerExitAccepted();

  @override
  String toString() => 'KioskServerExitAccepted';
}

/// `422 KIOSK_EXIT_CODE_INVALID {attemptsLeft}` — неверный, использованный или прежний код; на устройстве код
/// после этого не проверяется.
final class KioskServerExitInvalid extends KioskServerExitResult {
  const KioskServerExitInvalid(this.attemptsLeft);

  final int? attemptsLeft;

  @override
  String toString() => 'KioskServerExitInvalid($attemptsLeft)';
}

/// `423 KIOSK_EXIT_LOCKED {retryAfter}` — 5 неверных подряд, пауза 15 мин; на устройстве код не проверяется.
final class KioskServerExitLocked extends KioskServerExitResult {
  const KioskServerExitLocked(this.retryAfter);

  final Duration? retryAfter;

  @override
  String toString() => 'KioskServerExitLocked(${retryAfter?.inSeconds} s)';
}

/// Сервер код не проверил — проверка на устройстве: нет сети, таймаут, `426`, `401 SESSION_REVOKED` (срок сессии
/// вышел), `403 KIOSK_DISABLED`, `403 KIOSK_NETWORK_DENIED` (ADR-115 п. 28) и любой другой ответ без проверки кода.
final class KioskServerExitNotChecked extends KioskServerExitResult {
  const KioskServerExitNotChecked();

  @override
  String toString() => 'KioskServerExitNotChecked';
}

/// Порт жизненного цикла планшета на сервере.
abstract interface class KioskLifecycleRepository {
  /// `POST /kiosk/exit {code}` (`kiosk.self.exit`): без ключа идемпотентности и без автоповтора. Код не логируется.
  Future<KioskServerExitResult> exit(String code);

  /// Проверка склада планшета одним лёгким запросом по складу (`GET /catalog/categories?depth=1`, не `GET /me`): пока
  /// SCR-51 показывает «Сервис временно недоступен» по складу (`403 FORBIDDEN kiosk_warehouse_unavailable`), heartbeat
  /// шлёт его раз в период; успешный ответ снимает состояние (02 SCR-51.7). Ошибки не бросает, ответ не разбирает.
  Future<void> probeWarehouse();
}

/// Реализация порта (корень — `data/kiosk_bindings.dart`); `null` — без сервера (код проверяется на устройстве).
final kioskLifecycleRepositoryProvider = Provider<KioskLifecycleRepository?>((ref) => null);

/// Оформление заявки с планшета (`/kiosk/order-otp`, `/kiosk/orders`; корень — `data/kiosk_bindings.dart`); `null` —
/// без сервера: шаги SCR-52 / SCR-53 пусты.
final kioskRepositoryProvider = Provider<KioskRepository?>((ref) => null);

/// Корзина планшета для оформления (корень — `app/router/shells/kiosk_mode_bindings.dart`, корзина фичи cart); `null` —
/// не подключена: шаги SCR-52 / SCR-53 пусты. Новый объект порта на каждое поколение корзины (сброс FLOW-045)
/// очищает память оформления — номер, `challengeId`, код и ключ.
final kioskCheckoutCartProvider = Provider<KioskCheckoutCart?>((ref) => null);
