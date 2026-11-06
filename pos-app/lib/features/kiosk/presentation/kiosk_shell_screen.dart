// Экран режима «Планшет магазина» — общий каркас маршрутов SCR-51 `/kiosk`, SCR-52 `/kiosk/checkout`, SCR-53
// `/kiosk/done` (02 ч. F; `visual/navigation.md` §2.1, §3; P-002 §9; ADR-115; 13 TAB-2-01).
//
// Маршруты режима — вне оболочки `AppShell` (`app/router/kiosk_routes.dart`, корневой навигатор): нет нижней панели,
// rail, drawer навигации, меню аватара, колокольчика, `SyncIndicator`, HID-сканера и горячих клавиш сотрудника
// (navigation.md §2.1, §9). Уйти с маршрутов режима нельзя: переходы на другие пути возвращает на `/kiosk` guard G-15
// (navigation.md §4.1), «Назад» из режима не выводит (закрепление, P-002 §8.10) — каркас не отдаёт `pop` наружу.
// Содержимое `/kiosk` — тело витрины SCR-51 из порта [kioskCatalogBodyProvider] (фича catalog, TAB-2-03); шаги
// оформления SCR-52 и SCR-53 маршрут передаёт в [KioskShellScreen.child] (TAB-2-04).
//
// Автосброс FLOW-045 (TAB-2-05): каркас держит монитор бездействия [KioskIdleMonitor] — касания, «Вы ещё здесь?»,
// гашение экрана, уход в фон, отзыв планшета; на SCR-53 таймера бездействия нет (свой таймер `kiosk_done_seconds`,
// 02 SCR-53.4). Тело витрины строится заново на каждое поколение сброса ([kioskResetGenerationProvider]): после
// автосброса следующий покупатель видит стартовую категорию без прежнего поиска, фильтров, вида и прокрутки.
//
// Жизненный цикл (TAB-2-10): состояния планшета 02 SCR-51.7 поверх содержимого ([KioskStateView]: «Планшет нужно
// обновить», «Планшет не в сети магазина», «Сервис временно недоступен», «Планшет нужно подключить заново»,
// «Планшет отключён администратором»; аварийный выход — долгое нажатие на логотип) и связь с сервером не реже раза в
// 5 мин ([KioskHeartbeatScope], ADR-115 п. 21).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_heartbeat.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_idle_monitor.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_reset_orchestrator.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';

/// Каркас экранов режима «Планшет магазина» (SCR-51…SCR-53).
class KioskShellScreen extends ConsumerWidget {
  const KioskShellScreen({this.args = const KioskCatalogArgs(), this.child, super.key});

  /// Корневой ключ каркаса (тесты guard-ов и маршрутов режима).
  static const Key screenKey = ValueKey<String>('kiosk-shell');

  /// Параметры витрины SCR-51 (`/kiosk?c=`; строка поиска в адрес не пишется — 02 ч. F, правило 3).
  final KioskCatalogArgs args;

  /// Содержимое шага оформления (SCR-52 `/kiosk/checkout`, SCR-53 `/kiosk/done`); `null` — витрина SCR-51 из порта
  /// [kioskCatalogBodyProvider].
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget? content = child ?? _showcase(context, ref);
    return PopScope<Object?>(
      key: screenKey,
      // Корень режима: системное «Назад» планшет из режима не выводит (P-002 §8.10; navigation.md §6.2).
      canPop: false,
      child: KioskIdleMonitor(
        // SCR-53: свой таймер `kiosk_done_seconds`, диалога «Вы ещё здесь?» нет (02 SCR-53.4).
        idleReset: child is! KioskDoneScreen,
        child: Scaffold(
          backgroundColor: context.colors.background,
          // Без привязки корня — пустой фон (без бесконечной анимации: экран не «ждёт» данных), как SCR-50.
          body: KioskHeartbeatScope(child: KioskStateView(child: content ?? const SizedBox.expand())),
        ),
      ),
    );
  }

  /// Тело витрины SCR-51 текущего поколения сброса (состояние прежнего покупателя не переносится).
  Widget? _showcase(BuildContext context, WidgetRef ref) {
    final KioskCatalogBodyBuilder? builder = ref.watch(kioskCatalogBodyProvider);
    if (builder == null) return null;
    final int generation = ref.watch(kioskResetGenerationProvider);
    return KeyedSubtree(key: ValueKey<int>(generation), child: builder(context, args));
  }
}
