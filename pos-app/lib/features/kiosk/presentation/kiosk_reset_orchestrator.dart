// Оркестратор сброса планшета магазина FLOW-045 (04 FLOW-045.S3–S6, A1, A2, E1; 02 ч. F UI-51-005, UI-51-016,
// SCR-51.7 «Сброс без сети», SCR-51.11, SCR-52 «Автосброс», SCR-53.4; 08 §4.25.4; 10 KIOSK-020, KIOSK-021,
// KIOSK-025; 11 PRIV-033; P-002 §8.8, §15; ADR-115; 13 TAB-2-05).
//
// Одна точка сброса для «Начать заново» SCR-51 и «Готово» SCR-53 (порт фичи catalog `catalogKioskStartOverProvider`,
// привязка — корень `app/router/shells/kiosk_mode_bindings.dart` через [kioskStartOverPort]), для автосброса без
// касаний, гашения экрана, ухода в фон, отзыва планшета и состояний, в которых покупка невозможна (`426`,
// полноэкранные UI-51-015 кроме отзыва — FLOW-044.E3; монитор `kiosk_idle_monitor.dart`):
// 1. Память покупателя — сразу, до сети: слои корневого навигатора без страницы (drawer корзины, карточка товара,
//    листы SCR-15/16, «Подробнее» SCR-52, диалоги), снекбары и фокус; номер, `challengeId`, код, ключ
//    идемпотентности, `previewToken` и номер заявки (`KioskCheckoutController.clear`); буфер обмена. Сброс извне
//    экрана (автосброс, фон) ещё и строит тело витрины заново ([kioskResetGenerationProvider]: стартовая категория,
//    пустой поиск, фильтры, вид и сортировка по умолчанию, прокрутка к началу) и открывает `/kiosk`; «Начать заново» и
//    «Готово» приводят свой экран в начальное состояние сами.
// 2. Сервер — `POST /kiosk/reset {cartId}` через корзину планшета (`KioskCartControl.reset`): метка
//    `app_meta.kiosk.pending_reset_cart_id` (только id корзины) пишется до запроса, корзина на экране сразу пуста,
//    изменения и `GET /cart` до `200` не выполняются. Корзины на экране не было или сервер её не знает (`404`) —
//    закрывается текущая активная корзина планшета (`GET /cart` → `POST /kiosk/reset`); её содержимое не показывается.
// 3. Без сети и при отказе (`401`, `403`, `426`, `5xx`) метка остаётся (FLOW-045.E1); повторы — через 5, 15, 60 с,
//    затем раз в минуту; при запуске (первый экран режима), при возврате связи и при снятии состояния планшета первым
//    запросом корзины идёт `POST /kiosk/reset` с этим id (FLOW-045.A1, KIOSK-025). Пока сессии нет или сервер
//    отказывает планшету `403` (`KIOSK_NETWORK_DENIED`, «Сервис временно недоступен»), запрос сброса не уходит —
//    метка ждёт снятия состояния, повторов `403` раз в минуту нет.
// Двойной сброс (автосброс и «Начать заново» одновременно) — один запрос (SCR-51.11). Отзыв планшета
// (`401 KIOSK_REVOKED`) — только память, без запроса (FLOW-045.S6). Номеров, кодов и тел запросов здесь нет; ничего не
// логируется (журнал `kiosk.session_reset` пишет сервер, 11 §6.1).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';

/// Причина сброса FLOW-045.
enum KioskResetReason {
  /// «Начать заново» в шапке SCR-51; «Готово», конец таймера и «Назад» SCR-53 (порт `catalogKioskStartOverProvider`):
  /// экран-инициатор сам приводит себя в начальное состояние и сам переходит на SCR-51.
  startOver,

  /// Конец отсчёта «Вы ещё здесь?» или «Начать заново» в диалоге (UI-51-016).
  idle,

  /// Гашение экрана, уход приложения в фон (FLOW-045.S6) — немедленно, без диалога.
  background,

  /// Отзыв планшета `401 KIOSK_REVOKED` (FLOW-045.S6): только память, без запроса и без перехода (SCR-51 показывает
  /// «Планшет отключён администратором», затем SCR-01).
  revoked,

  /// Покупка невозможна (FLOW-044.E3): `426 APP_UPDATE_REQUIRED` или полноэкранное состояние UI-51-015 (кроме отзыва) —
  /// память, слои и корзина покупателя очищаются при входе в состояние, как при автосбросе; запрос сброса — когда
  /// сессия планшета жива (иначе метка ждёт снятия состояния). Открытый аварийный выход не закрывается.
  blocked;

  /// Сброс извне экрана: тело витрины строится заново.
  bool get rebuildsShowcase => this != startOver;

  /// Переход на SCR-51 `/kiosk` со стартовой категорией.
  bool get opensShowcase => this == idle || this == background || this == blocked;
}

/// Повторы сброса без сети (FLOW-045.A1; 02 SCR-51.7 «Сброс без сети»): через 5, 15, 60 с, затем раз в минуту.
abstract final class KioskResetRetry {
  static const List<Duration> delays = <Duration>[Duration(seconds: 5), Duration(seconds: 15), Duration(seconds: 60)];

  /// Дальше — раз в минуту.
  static const Duration period = Duration(seconds: 60);

  /// Пауза перед повтором номер [attempt] (с нуля).
  static Duration after(int attempt) => attempt < delays.length ? delays[attempt] : period;
}

/// Поколение тела витрины SCR-51: сброс извне экрана — новое поколение, `KioskShellScreen` строит тело заново (всё
/// состояние витрины — только в `State` экрана, 02 SCR-51.11).
final kioskResetGenerationProvider = NotifierProvider<KioskResetGeneration, int>(KioskResetGeneration.new);

/// Состояние [kioskResetGenerationProvider].
final class KioskResetGeneration extends Notifier<int> {
  @override
  int build() => 0;

  /// Новое поколение.
  void next() => state++;
}

/// Сброс планшета (один на приложение).
final class KioskResetOrchestrator {
  KioskResetOrchestrator(this._ref);

  final Ref _ref;

  /// Контекст верхнего экрана режима (корневой навигатор, роутер); `null` — экраны режима закрыты (оркестратор не
  /// активен: повторов и подписки на сеть нет).
  BuildContext? Function()? _screen;
  ProviderSubscription<OnlineStatus>? _online;

  /// Идущий запрос сброса (двойной сброс — один запрос).
  Future<bool>? _server;
  Timer? _retry;
  int _attempt = 0;

  /// Сброс не подтверждён сервером, а метки нет (корзины на экране не было — закрыть текущую активную).
  bool _owed = false;
  int _epoch = 0;

  /// Счётчик сбросов: растёт в начале каждого сброса (монитор отличает диалог, закрытый сбросом).
  int get epoch => _epoch;

  /// Экран режима открыт.
  bool get isActive => _screen != null;

  /// Запланирован повтор сброса без сети.
  bool get retryScheduled => _retry != null;

  /// Номер следующего повтора (с нуля): пауза — [KioskResetRetry.after].
  int get attempt => _attempt;

  KioskCartControl? get _control => _ref.read(kioskCartControlProvider);

  /// Сессия планшета есть и сервер её принимает: запрос к серверу имеет смысл. Без сессии, при отзыве и пока сервер
  /// отказывает планшету `403` («Не в сети магазина», «Сервис временно недоступен») — нет: метка остаётся до снятия
  /// состояния ([resume]), `403` раз в минуту не повторяется.
  bool get _sessionAlive => switch (_ref.read(kioskStatusProvider)) {
    KioskStatus.none ||
    KioskStatus.reconnectNeeded ||
    KioskStatus.revoked ||
    KioskStatus.networkDenied ||
    KioskStatus.unavailable => false,
    KioskStatus.ready || KioskStatus.updateNeeded => true,
  };

  bool _owes(KioskCartControl control) => _owed || control.pendingResetCartId != null;

  /// Экран режима открыт ([screen] — контекст верхнего экрана): первым запросом — сброс по метке без сети.
  void activate(BuildContext? Function() screen) {
    _screen = screen;
    unawaited(resume());
  }

  /// Экраны режима закрыты: повторов и подписки на сеть нет.
  void deactivate() {
    _screen = null;
    _online?.close();
    _online = null;
    _cancelRetry();
  }

  /// Сброс по метке без сети, если она есть (запуск, возврат связи, возврат из фона, снято полноэкранное состояние):
  /// повторы начинаются заново (5, 15, 60 с, затем раз в минуту).
  Future<void> resume() async {
    final KioskCartControl? control = _control;
    if (!isActive || control == null) return;
    _listenOnline();
    if (!_sessionAlive) return;
    await control.prepare();
    if (!isActive || !_ref.mounted || !_owes(control)) return;
    _cancelRetry();
    _attempt = 0;
    if (!await _serverReset() && isActive && _retry == null) _scheduleRetry();
  }

  /// Сброс FLOW-045 по причине [reason]: память — сразу, затем `POST /kiosk/reset` (кроме отзыва). Отказ и сеть —
  /// метка и повторы; ошибка покупателю не показывается.
  Future<void> reset(KioskResetReason reason) async {
    if (!_ref.mounted) return;
    _epoch++;
    // Память оформления — до перехода: SCR-52 пишет шаг в адрес (`replace`), и это не должно перебить `go('/kiosk')`.
    _ref.read(kioskCheckoutControllerProvider.notifier).clear();
    _clearScreen(home: reason.opensShowcase, keepEmergencyExit: reason == KioskResetReason.blocked);
    if (reason.rebuildsShowcase) _ref.read(kioskResetGenerationProvider.notifier).next();
    final Future<void> clipboard = _clearClipboard();
    if (reason == KioskResetReason.revoked) {
      _owed = false;
      _cancelRetry();
      await clipboard;
      return;
    }
    final bool settled = await _serverReset();
    await clipboard;
    if (!settled && isActive && _retry == null) _scheduleRetry();
  }

  void dispose() {
    _online?.close();
    _online = null;
    _cancelRetry();
    _screen = null;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Сервер
  // ---------------------------------------------------------------------------------------------------------------

  /// `true` — сброс подтверждён (или закрывать нечего), `false` — метка осталась, нужен повтор.
  Future<bool> _serverReset() {
    final Future<bool>? running = _server;
    if (running != null) return running;
    final Future<bool> started = _serverResetOnce().whenComplete(() => _server = null);
    _server = started;
    return started;
  }

  Future<bool> _serverResetOnce() async {
    final KioskCartControl? control = _control;
    final KioskRepository? repo = _ref.read(kioskRepositoryProvider);
    if (control == null || repo == null) {
      // Не планшет или сервер не подключён: закрывать на сервере нечего.
      _owed = false;
      return true;
    }
    _listenOnline();
    final Result<Cart> r = await control.reset((String? cartId) => _request(repo, cartId));
    if (!_ref.mounted) return true;
    if (r.isSuccess) {
      _owed = false;
      _attempt = 0;
      _cancelRetry();
      return true;
    }
    _owed = true;
    return false;
  }

  /// Запрос сброса корзины [cartId] (метка или корзина на экране); корзины не было или `404` — закрыть текущую активную
  /// корзину планшета, не показывая её.
  Future<Result<Cart>> _request(KioskRepository repo, String? cartId) async {
    // Без сессии планшета (подключите заново) запрос не уходит: метка остаётся до сессии.
    if (!_sessionAlive) return const FailureResult<Cart>(UnknownFailure());
    if (cartId != null) {
      final Result<Cart> r = await repo.reset(cartId);
      // `404` — корзина не этого планшета или исчезла: закрыть текущую активную (ниже).
      final bool notFound = switch (r) {
        FailureResult<Cart>(failure: ServerFailure(problemCode: ProblemCode.notFound)) => true,
        _ => false,
      };
      if (!notFound) return r;
    }
    final CartRepository carts;
    try {
      carts = _ref.read(cartRepositoryProvider);
    } on Object {
      return const FailureResult<Cart>(UnknownFailure());
    }
    final Result<Cart> current = await carts.fetch();
    return switch (current) {
      Success<Cart>(:final Cart value) => repo.reset(value.id),
      FailureResult<Cart>() => current,
    };
  }

  void _listenOnline() {
    if (_online != null || !isActive || _control == null) return;
    // Подписка контейнера, а не провайдера: оркестратор только читают, а подписки провайдера без слушателей
    // Riverpod приостанавливает.
    _online = _ref.container.listen<OnlineStatus>(cartOnlineStatusProvider, (
      OnlineStatus? previous,
      OnlineStatus next,
    ) {
      // Связь вернулась — первым запросом корзины сброс по метке.
      if (next == OnlineStatus.online && previous != OnlineStatus.online) unawaited(resume());
    });
  }

  void _scheduleRetry() {
    _retry?.cancel();
    final Duration delay = KioskResetRetry.after(_attempt);
    _attempt++;
    _retry = Timer(delay, () {
      _retry = null;
      unawaited(_retryNow());
    });
  }

  Future<void> _retryNow() async {
    final KioskCartControl? control = _control;
    if (!isActive || control == null || !_owes(control)) return;
    if (!await _serverReset() && isActive && _retry == null) _scheduleRetry();
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Экран
  // ---------------------------------------------------------------------------------------------------------------

  /// Закрыть слои, снекбары и фокус; [home] — открыть SCR-51 `/kiosk` (без категории — стартовая);
  /// [keepEmergencyExit] — диалог аварийного выхода (данных покупателя в нём нет) остаётся открытым.
  void _clearScreen({required bool home, bool keepEmergencyExit = false}) {
    FocusManager.instance.primaryFocus?.unfocus();
    final BuildContext? context = _screen?.call();
    if (context == null) return;
    _closeLayers(context, keepEmergencyExit: keepEmergencyExit);
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    if (!home) return;
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    router.go(KioskCheckoutLocations.showcase);
    // Слои под снятыми страницами (drawer корзины под SCR-52) остаются над `/kiosk` — закрыть после смены страниц.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      final BuildContext? top = _screen?.call();
      if (top != null) _closeLayers(top, keepEmergencyExit: keepEmergencyExit);
    });
  }

  /// Маршруты корневого навигатора без страницы над верхней страницей (drawer, слой карточки, листы, диалоги);
  /// [keepEmergencyExit] — до диалога аварийного выхода (он и всё под ним остаются).
  static void _closeLayers(BuildContext context, {bool keepEmergencyExit = false}) {
    Navigator.maybeOf(context, rootNavigator: true)?.popUntil(
      (Route<dynamic> route) =>
          route.settings is Page<Object?> ||
          route.isFirst ||
          (keepEmergencyExit && route.settings.name == kioskEmergencyExitRouteName),
    );
  }

  /// Буфер обмена пуст после каждого сброса (11 PRIV-033; ADR-115 п. 27).
  static Future<void> _clearClipboard() async {
    try {
      await Clipboard.setData(const ClipboardData(text: ''));
    } on Object {
      // Буфер недоступен (браузер без разрешения, платформа без буфера) — сброс продолжается.
    }
  }
}

/// Оркестратор сброса (один на приложение).
final kioskResetOrchestratorProvider = Provider<KioskResetOrchestrator>((ref) {
  final KioskResetOrchestrator orchestrator = KioskResetOrchestrator(ref);
  ref.onDispose(orchestrator.dispose);
  return orchestrator;
});

/// Порт «Начать заново» SCR-51 и «Готово» SCR-53 для фичи catalog (`catalogKioskStartOverProvider`): привязывает корень
/// режима планшета (`kiosk_mode_bindings.dart`).
Future<void> Function() kioskStartOverPort(Ref ref) {
  final KioskResetOrchestrator orchestrator = ref.watch(kioskResetOrchestratorProvider);
  return () => orchestrator.reset(KioskResetReason.startOver);
}
