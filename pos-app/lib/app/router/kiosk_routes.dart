// Маршруты режима «Планшет магазина» (P-002 §9; ADR-115; 06 §6.2 «Размещение режима…» п. (2), §6.4; 13 TAB-2-01):
// SCR-51 `/kiosk?c=`, SCR-52 `/kiosk/checkout?step=`, SCR-53 `/kiosk/done` (`visual/navigation.md` §3). Строка поиска
// витрины в адрес не пишется и из адреса не читается (02 ч. F, правило 3; PRIV-033): `q` в `/kiosk?…` не учитывается.
//
// Обычный список `GoRoute` root-уровня (без генерации кода, как `devRoutes()` в app_router.dart) — **вне**
// `StatefulShellRoute` оболочки `AppShell`: порядок веток `ShellBranch` и карта маршрутов ядра R0 §9 (`$appRoutes`)
// не меняются. Доступ: сессия `kind=kiosk` — только эти три пути (guard G-15 в `guards/auth_guard.dart`), сотрудник и
// `customer` на `/kiosk*` уходят на главный экран своего режима (`guards/role_guard.dart`), гость — по G-1.
// Карточка товара планшета — слой поверх `/kiosk` без маршрута (`/catalog/p/{productId}` закрыт G-15, ADR-115 п. 22).
// SCR-52 открывается из drawer корзины `push` над `/kiosk` (drawer остаётся под ним); шаг `step` экран пишет сам
// заменой записи. SCR-53 — `go('/kiosk/done')`: страница `/kiosk` уходит вместе с drawer (13 TAB-2-04).
import 'package:go_router/go_router.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_shell_screen.dart';

/// Пути режима «Планшет магазина» (navigation.md §3).
abstract final class KioskPaths {
  /// SCR-51 — витрина и корзина; главный экран режима `AppMode.kiosk` (`homeLocationFor`).
  static const String showcase = '/kiosk';

  /// SCR-52 — оформление заявки (`step=phone|code`).
  static const String checkout = '/kiosk/checkout';

  /// SCR-53 — заявка отправлена.
  static const String done = '/kiosk/done';

  /// Все пути, на которых может находиться сессия планшета (G-15).
  static const Set<String> all = <String>{showcase, checkout, done};
}

/// Путь разрешён сессии планшета (G-15: `путь ∈ {/kiosk, /kiosk/checkout, /kiosk/done}`; query не учитывается).
bool isKioskModePath(String path) => KioskPaths.all.contains(path);

/// Путь режима планшета для других видов сессии (G-15: «путь начинается с `/kiosk`» — `/kiosk` и `/kiosk/…`).
bool isKioskPath(String path) => path == KioskPaths.showcase || path.startsWith('${KioskPaths.showcase}/');

/// Маршруты режима планшета root-уровня (корневой навигатор, вне `AppShell`).
List<RouteBase> kioskRoutes() => <RouteBase>[
  GoRoute(
    path: KioskPaths.showcase,
    builder: (context, state) => KioskShellScreen(
      args: KioskCatalogArgs(categoryId: state.uri.queryParameters['c']),
    ),
  ),
  // SCR-52 и SCR-53 — шаги оформления в каркасе режима (`KioskShellScreen.child`, 13 TAB-2-04).
  GoRoute(
    path: KioskPaths.checkout,
    builder: (context, state) =>
        KioskShellScreen(child: KioskCheckoutScreen(step: KioskCheckoutStep.parse(state.uri.queryParameters['step']))),
  ),
  GoRoute(
    path: KioskPaths.done,
    builder: (context, state) => const KioskShellScreen(child: KioskDoneScreen()),
  ),
];
