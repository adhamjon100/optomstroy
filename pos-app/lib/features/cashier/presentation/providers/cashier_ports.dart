// Порты экранов кассира SCR-30 и SCR-38 — зависимости presentation, которые фича cashier не может взять сама
// (DAG 06 §6.1: cashier → orders, customers; роль — из профиля входа фичи auth, печать — пакет `printing` корня).
// Значения по умолчанию работают без переопределений корня:
// - роль — `syncViewerRoleProvider` core/sync (корень уже подставляет в него роль профиля входа, catalog_offline_bindings);
// - сеть — `onlineStatusProvider`, блокировка сессии — `sessionControllerProvider`;
// - step-up — `StepUpCoordinator` core/session (StepUpDialog: PIN / код из SMS; вариант `supervisor` — R2, CASH-007);
// - печать чека — `null` (чекбокс печати недоступен), пока корень не подставит принтер (как `checkoutPrinterProvider`).
// В widget-тестах все порты переопределяются (`overrideWithValue`).
import 'package:flutter/widgets.dart' show BuildContext, VoidCallback, WidgetBuilder;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_controller.dart'
    show sessionControllerProvider, stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/session_state.dart' show SessionLockReason;
import 'package:optomstroy/core/session/step_up_coordinator.dart' show StepUpChallenge, StepUpCoordinator;
import 'package:optomstroy/core/sync/sync_providers.dart' show syncViewerRoleProvider;
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:uuid/uuid.dart';

/// Роль текущего пользователя (видимость кассовых действий — 02 SCR-30.10, SCR-38.10). Сервер проверяет права сам
/// (CASH-001): скрытие кнопок — подсказка, не защита.
final cashierViewerRoleProvider = Provider<RoleCode?>((ref) => ref.watch(syncViewerRoleProvider));

/// Есть ли сеть: кассовые операции — только онлайн (PAY-008, P-OFFLINE).
final cashierOnlineProvider = Provider<bool>((ref) {
  final OnlineStatus? s = ref.watch(onlineStatusProvider).value;
  return s != OnlineStatus.offline;
});

/// Сессия заблокирована (idle-блокировка SCR-08): polling дашборда и ожидание QR приостанавливаются (SESS-024).
final cashierSessionLockedProvider = Provider<bool>(
  (ref) => ref.watch(sessionControllerProvider.select((s) => s.isLocked)),
);

/// Область сеанса: память незавершённых операций — только текущего сеанса (CASH-015, P-IDEMP «после выхода ключей
/// нет»). Каждая смена пользователя сессии (выход → `null`, вход, смена кассира) даёт **новый** объект области, поэтому
/// зависимые провайдеры пересобираются и тогда, когда после выхода снова входит тот же пользователь, а память на
/// момент выхода никто не слушал (провайдер на паузе пересчитывается при чтении и иначе вернул бы прежний `userId`).
final cashierSessionScopeProvider = Provider<Object>((ref) {
  ref.watch(sessionControllerProvider.select((s) => s.userId));
  return Object();
});

/// Итог step-up до запроса: [cancelled] — пользователь закрыл `StepUpDialog`; [token] `null` без отмены — диалог не
/// смонтирован (step-up выполнит AuthInterceptor по `403 STEP_UP_REQUIRED`).
typedef CashierStepUpResult = ({bool cancelled, String? token});

/// Step-up для операции (`payment.qr.confirm_manual`, `payment.void`).
typedef CashierStepUp = Future<CashierStepUpResult> Function(String operation);

/// Step-up через координатор core/session (кэш токена области 15 мин — память процесса).
final cashierStepUpProvider = Provider<CashierStepUp>((ref) {
  return (String operation) async {
    final StepUpCoordinator coordinator = ref.read(stepUpCoordinatorProvider);
    if (!coordinator.hasPresenter) return (cancelled: false, token: null);
    final String? token = await coordinator.obtain(StepUpChallenge(operation: operation));
    return (cancelled: token == null, token: token);
  };
});

/// Новый `Idempotency-Key` (UUID v4) — только память процесса (ядро §22.6, P-IDEMP).
final cashierKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Печать товарного чека 80 мм (UI-38-006): `true` — отправлено на печать. `null` — принтер не подключён: чекбокс
/// печати `disabled` («Настройте принтер»). Подставляет корень (тот же принтер, что у SCR-22).
typedef CashierReceiptPrinter = Future<bool> Function(OrderDocumentFile file);

/// Принтер чека; `null` — печать недоступна.
final cashierReceiptPrinterProvider = Provider<CashierReceiptPrinter?>((ref) => null);

/// Печать чека по умолчанию (настройка SCR-42; до подключения — включена, если принтер есть).
final cashierPrintReceiptByDefaultProvider = Provider<bool>((ref) => true);

/// Период автообновления дашборда (02 SCR-30.4: 60 с [НЕ ПОДТВЕРЖДЕНО, Q-176]); `null` — без таймера (тесты).
final cashierDashboardPollProvider = Provider<Duration?>((ref) => const Duration(seconds: 60));

// ---------------------------------------------------------------------------------------------------------------
// Шапка SCR-30 (02 SCR-30.3 UI-30-013): логотип, пользователь «Имя · Кассир», меню аватара, `SyncIndicator`.

/// Имя пользователя для шапки (профиль входа — только память); `null` — вместо имени подпись роли.
final cashierViewerNameProvider = Provider<String?>((ref) => null);

/// Логотип шапки (корень подставляет логотип приложения, как у SCR-10); `null` — без логотипа.
final cashierLogoProvider = Provider<WidgetBuilder?>((ref) => null);

/// `SyncIndicator` шапки (core/sync, тап → SCR-43); `null` — иконка синхронизации со ссылкой на SCR-43.
final cashierSyncIndicatorProvider = Provider<WidgetBuilder?>((ref) => null);

/// «Заблокировать» в меню аватара (SCR-08, ручная блокировка); `null` — пункта нет.
final cashierLockProvider = Provider<VoidCallback?>(
  (ref) =>
      () => ref.read(sessionControllerProvider.notifier).lock(SessionLockReason.manual),
);

/// «Выйти» в меню аватара: подтверждение и `POST /auth/logout` (корень — тот же сценарий, что у SCR-10, с
/// предупреждением о неотправленных изменениях FLOW-009.E1).
typedef CashierLogout = Future<void> Function(BuildContext context, WidgetRef ref);

/// Выход; `null` — пункта нет (корень не подставил сценарий).
final cashierLogoutProvider = Provider<CashierLogout?>((ref) => null);
