// Автосброс планшета магазина по бездействию и немедленный сброс при гашении экрана, уходе в фон и отзыве планшета
// (04 FLOW-045.S1–S3, S5, S6; 02 ч. F SCR-51.4 «Касание любого места экрана», UI-51-016, AC-UI-51-014, SCR-52
// «Автосброс», AC-UI-52-017, SCR-53.4, AC-UI-53-005; 03 §9.45 `countdown`, DS-103, A11Y-023; 10 KIOSK-020; Р-09 (а);
// 13 TAB-2-05).
//
// Монитор один на приложение ([kioskIdleControllerProvider]); его держат экраны режима ([KioskIdleMonitor] в каркасе
// `KioskShellScreen` всех трёх маршрутов), последний закрытый экран снимает таймеры, подписки и наблюдателей:
// - касание любого места экрана (все указатели приложения, в том числе над drawer корзины, листами и слоем карточки —
//   глобальный маршрут `PointerRouter`) и клавиши подключённой клавиатуры перезапускают таймер `kiosk_idle_seconds`
//   (`kioskTimingsProvider`, по умолчанию 120 с; значения — из `GET /settings/public`);
// - таймер не идёт на SCR-53 (там свой таймер `kiosk_done_seconds`), пока открыт диалог аварийного выхода, во время
//   «Отправляем заявку…» на SCR-52 (UI-52-013: идёт восстановление по ключу идемпотентности до 15 мин, SCR-52.4), в
//   полноэкранных состояниях UI-51-015 и без режима планшета;
// - конец таймера — диалог «Вы ещё здесь?» ([KioskIdleDialog]) с отсчётом `kiosk_idle_warning_seconds` (15 с):
//   «Продолжить», Esc, «Назад» и тап по затемнению — таймер заново, данные покупателя сохраняются; «Начать заново» и
//   конец отсчёта — сброс ([KioskResetOrchestrator], SCR-51 стартовой категории);
// - гашение экрана и уход приложения в фон (`hidden`, `paused`) — немедленный сброс без диалога на любом экране режима
//   (открытый диалог закрывается сбросом); возврат (`resumed`) — сброс по метке без сети первым запросом;
// - отзыв планшета (`KioskStatus.revoked`) — очистка памяти без запроса; вход в состояние, где покупка невозможна
//   (`426` и полноэкранные UI-51-015 кроме отзыва, FLOW-044.E3), — сброс как при автосбросе (память, слои, корзина,
//   SCR-51); снято такое состояние (в том числе `426` → обычная работа) — сброс по метке первым запросом корзины.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_idle_dialog.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_reset_orchestrator.dart';

/// Экран режима, который держит монитор.
abstract interface class KioskIdleHolder {
  BuildContext get context;

  bool get mounted;

  /// На экране действует таймер бездействия (SCR-51, SCR-52); `false` — SCR-53.
  bool get idleReset;
}

/// Монитор бездействия и жизненного цикла приложения в режиме планшета.
final class KioskIdleController with WidgetsBindingObserver {
  KioskIdleController(this._ref);

  final Ref _ref;
  final List<KioskIdleHolder> _holders = <KioskIdleHolder>[];
  KioskResetOrchestrator? _orchestrator;
  ProviderSubscription<KioskStatus>? _status;

  /// «Отправляем заявку…» на SCR-52: пока идёт, таймер бездействия стоит.
  ProviderSubscription<bool>? _sending;
  Timer? _idle;
  Timer? _countdown;
  RawDialogRoute<bool>? _dialog;

  /// Приложение скрыто (экран погашен или в фоне) до `resumed`.
  bool _backgrounded = false;

  /// Таймер бездействия идёт.
  bool get isRunning => _idle != null;

  /// Открыт диалог «Вы ещё здесь?».
  bool get warningShown => _dialog != null;

  /// Экран режима открыт ([holder]); первый — подписки, наблюдатели и первый запрос сброса по метке.
  void hold(KioskIdleHolder holder) {
    final bool first = _holders.isEmpty;
    _holders.add(holder);
    if (first) _start();
    restart();
  }

  /// Экран режима закрыт; последний — всё снимается.
  void release(KioskIdleHolder holder) {
    if (!_holders.remove(holder)) return;
    if (_holders.isEmpty) {
      _stop();
      return;
    }
    restart();
  }

  /// Экран сменил признак [KioskIdleHolder.idleReset].
  void changed() => restart();

  /// Касание или клавиша: таймер заново (пока открыт диалог — решает диалог).
  void activity() {
    if (_dialog != null || _holders.isEmpty) return;
    restart();
  }

  /// Таймер бездействия заново, если он сейчас действует.
  void restart() {
    _idle?.cancel();
    _idle = null;
    if (!_canIdle) return;
    _idle = Timer(_ref.read(kioskTimingsProvider).idle, _onIdle);
  }

  bool get _canIdle =>
      _holders.isNotEmpty &&
      _holders.every((KioskIdleHolder h) => h.idleReset) &&
      _dialog == null &&
      !_backgrounded &&
      !kioskEmergencyExitShown.value &&
      !_ref.read(kioskCheckoutControllerProvider).sending &&
      _idleStatus(_ref.read(kioskStatusProvider));

  /// Таймер бездействия — в режиме планшета вне полноэкранных состояний UI-51-015 (там нет данных покупателя).
  static bool _idleStatus(KioskStatus s) => s != KioskStatus.none && !s.isFullScreen;

  /// Покупка невозможна (FLOW-044.E3): `426` и полноэкранные состояния UI-51-015, кроме отзыва (у него своя ветка без
  /// запроса). Вход — сброс данных покупателя, выход — сброс по метке.
  static bool _clearsBuyer(KioskStatus s) =>
      s == KioskStatus.updateNeeded || (s.isFullScreen && s != KioskStatus.revoked);

  BuildContext? _topContext() {
    for (final KioskIdleHolder h in _holders.reversed) {
      if (h.mounted) return h.context;
    }
    return null;
  }

  void _start() {
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    kioskEmergencyExitShown.addListener(restart);
    // Подписка контейнера: монитор только читают, а подписки провайдера без слушателей Riverpod приостанавливает.
    _status = _ref.container.listen<KioskStatus>(kioskStatusProvider, _onStatus);
    _sending = _ref.container.listen<bool>(
      kioskCheckoutControllerProvider.select((KioskCheckoutState s) => s.sending),
      (bool? previous, bool next) => restart(),
    );
    final KioskResetOrchestrator orchestrator = _ref.read(kioskResetOrchestratorProvider);
    _orchestrator = orchestrator;
    orchestrator.activate(_topContext);
  }

  void _stop() {
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    kioskEmergencyExitShown.removeListener(restart);
    _status?.close();
    _status = null;
    _sending?.close();
    _sending = null;
    _idle?.cancel();
    _idle = null;
    _countdown?.cancel();
    _countdown = null;
    _dialog = null;
    _backgrounded = false;
    _orchestrator?.deactivate();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerAddedEvent || event is PointerRemovedEvent) return;
    activity();
  }

  bool _onKey(KeyEvent event) {
    activity();
    // Клавиша не поглощается: её обработают поля, кнопки и экранная клавиатура.
    return false;
  }

  void _onIdle() {
    _idle = null;
    if (_canIdle) unawaited(_warn());
  }

  /// «Вы ещё здесь?»: отсчёт раз в секунду; итог — продолжить или сброс.
  Future<void> _warn() async {
    final BuildContext? context = _topContext();
    final NavigatorState? navigator = context == null ? null : Navigator.maybeOf(context, rootNavigator: true);
    final KioskResetOrchestrator? orchestrator = _orchestrator;
    if (context == null || navigator == null || orchestrator == null) return;
    final int warning = _ref.read(kioskTimingsProvider).idleWarning.inSeconds;
    final int seconds = warning < 1 ? 1 : warning;
    final ValueNotifier<int> remaining = ValueNotifier<int>(seconds);
    final RawDialogRoute<bool> route = kioskIdleDialogRoute(context, seconds: seconds, remaining: remaining);
    final int epoch = orchestrator.epoch;
    _dialog = route;
    _countdown = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (remaining.value > 0) remaining.value--;
      if (remaining.value > 0) return;
      timer.cancel();
      // Конец отсчёта — как «Начать заново».
      _close(route, false);
    });
    final bool? result = await navigator.push<bool>(route);
    if (identical(_dialog, route)) {
      _countdown?.cancel();
      _countdown = null;
      _dialog = null;
    }
    if (_holders.isEmpty || !_ref.mounted) return;
    // Диалог закрыт сбросом (гашение экрана, фон, отзыв) — второго сброса нет.
    if (result == false && orchestrator.epoch == epoch) unawaited(orchestrator.reset(KioskResetReason.idle));
    restart();
  }

  static void _close(Route<bool> route, bool? result) {
    final NavigatorState? navigator = route.navigator;
    if (!route.isActive || navigator == null) return;
    if (route.isCurrent) {
      navigator.pop<bool>(result);
    } else {
      navigator.removeRoute<bool>(route, result);
    }
  }

  void _onStatus(KioskStatus? previous, KioskStatus next) {
    // Не во время построения: переход навигатора и сброс — следующей микрозадачей.
    unawaited(Future<void>.microtask(() => _applyStatus(previous, next)));
  }

  void _applyStatus(KioskStatus? previous, KioskStatus next) {
    final KioskResetOrchestrator? orchestrator = _orchestrator;
    if (_holders.isEmpty || !_ref.mounted || orchestrator == null) return;
    if (next == KioskStatus.revoked && previous != KioskStatus.revoked) {
      // Отзыв: память покупателя — без запроса к серверу (FLOW-045.S6).
      unawaited(orchestrator.reset(KioskResetReason.revoked));
    } else {
      if (!_idleStatus(next)) {
        final RawDialogRoute<bool>? dialog = _dialog;
        if (dialog != null) _close(dialog, null);
      }
      final bool was = previous != null && _clearsBuyer(previous);
      if (_clearsBuyer(next) && !was) {
        // Покупка невозможна (FLOW-044.E3): номер, код, `challengeId`, корзина и слои прежнего покупателя не ждут
        // снятия состояния — сброс сразу (метка без сети и без сессии остаётся до снятия).
        unawaited(orchestrator.reset(KioskResetReason.blocked));
      } else if (was && !_clearsBuyer(next)) {
        // Снято (в том числе `426` → обычная работа): первым запросом корзины — сброс по метке.
        unawaited(orchestrator.resume());
      } else if (previous != null && !_idleStatus(previous) && _idleStatus(next)) {
        unawaited(orchestrator.resume());
      }
    }
    restart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final KioskResetOrchestrator? orchestrator = _orchestrator;
    if (_holders.isEmpty || orchestrator == null || !_ref.mounted) return;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_backgrounded) return;
        _backgrounded = true;
        _idle?.cancel();
        _idle = null;
        _countdown?.cancel();
        _countdown = null;
        // Гашение экрана и уход в фон — немедленный сброс без диалога (открытый диалог закрывает сброс).
        final KioskStatus status = _ref.read(kioskStatusProvider);
        if (status != KioskStatus.none && status != KioskStatus.revoked) {
          unawaited(orchestrator.reset(KioskResetReason.background));
        }
      case AppLifecycleState.resumed:
        if (!_backgrounded) return;
        _backgrounded = false;
        restart();
        unawaited(orchestrator.resume());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        return;
    }
  }

  void dispose() {
    if (_holders.isEmpty) return;
    _holders.clear();
    _stop();
  }
}

/// Монитор бездействия (один на приложение).
final kioskIdleControllerProvider = Provider<KioskIdleController>((ref) {
  final KioskIdleController controller = KioskIdleController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Держит монитор, пока экран режима открыт ([idleReset] — таймер бездействия на этом экране).
class KioskIdleMonitor extends ConsumerStatefulWidget {
  const KioskIdleMonitor({required this.child, this.idleReset = true, super.key});

  /// Таймер бездействия и диалог «Вы ещё здесь?» на этом экране (SCR-51, SCR-52); SCR-53 — `false`.
  final bool idleReset;
  final Widget child;

  @override
  ConsumerState<KioskIdleMonitor> createState() => _KioskIdleMonitorState();
}

class _KioskIdleMonitorState extends ConsumerState<KioskIdleMonitor> implements KioskIdleHolder {
  late final KioskIdleController _controller = ref.read(kioskIdleControllerProvider);

  @override
  bool get idleReset => widget.idleReset;

  @override
  void initState() {
    super.initState();
    _controller.hold(this);
  }

  @override
  void didUpdateWidget(KioskIdleMonitor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.idleReset != widget.idleReset) _controller.changed();
  }

  @override
  void dispose() {
    _controller.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
