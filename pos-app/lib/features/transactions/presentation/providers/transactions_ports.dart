// Порты экранов журнала операций SCR-36/SCR-37 — зависимости presentation, которые фича transactions не может взять
// сама (DAG 06 §6.1: transactions → orders, cashier, customers). Значения по умолчанию работают без корня:
// - роль — `syncViewerRoleProvider` core/sync (корень подставляет в него роль профиля входа);
// - сеть — `onlineStatusProvider`; step-up — `StepUpCoordinator` core/session;
// - список сотрудников для фильтра «Сотрудник» (`admin`/`owner`) — `null`: источника в 08 для этой фичи нет
//   (`/admin/users` — фича admin, вне DAG; З-07) — поле показывает только значение из URL (GQ-FECASH-07);
// - печать PDF (SCR-37 «Печать») — `null`: кнопка скрыта, пока корень не подставит принтер.
// В widget-тестах порты переопределяются (`overrideWithValue`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' show StepUpChallenge, StepUpCoordinator;
import 'package:optomstroy/core/sync/sync_providers.dart' show syncViewerRoleProvider;
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:uuid/uuid.dart';

/// Роль текущего пользователя (02 SCR-36.10, SCR-37.10). Сервер фильтрует сам (SEC-042).
final transactionsViewerRoleProvider = Provider<RoleCode?>((ref) => ref.watch(syncViewerRoleProvider));

/// Есть ли сеть (журнал и действия — только онлайн, CASH-015).
final transactionsOnlineProvider = Provider<bool>((ref) {
  final OnlineStatus? s = ref.watch(onlineStatusProvider).value;
  return s != OnlineStatus.offline;
});

/// Модуль заявок на возврат включён (`features.returnsFromPos`, P-FLAGS).
final transactionsReturnsEnabledProvider = Provider<bool>(
  (ref) => ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.returnsFromPos)),
);

/// Итог step-up до запроса.
typedef TransactionsStepUpResult = ({bool cancelled, String? token});

/// Step-up для операции (P-STEPUP-PRE для `payment.qr.confirm_manual`).
typedef TransactionsStepUp = Future<TransactionsStepUpResult> Function(String operation);

/// Step-up через координатор core/session.
final transactionsStepUpProvider = Provider<TransactionsStepUp>((ref) {
  return (String operation) async {
    final StepUpCoordinator coordinator = ref.read(stepUpCoordinatorProvider);
    if (!coordinator.hasPresenter) return (cancelled: false, token: null);
    final String? token = await coordinator.obtain(StepUpChallenge(operation: operation));
    return (cancelled: token == null, token: token);
  };
});

/// Новый `Idempotency-Key` (UUID v4; только память — P-IDEMP).
final transactionsKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Сотрудники точки для фильтра «Сотрудник» (`admin`/`owner`); `null` — источника нет.
typedef TransactionsActorsSource = Future<Result<List<UserRef>>> Function();

/// Источник списка сотрудников.
final transactionsActorsProvider = Provider<TransactionsActorsSource?>((ref) => null);

/// Печать PDF документа заказа (SCR-37 «Печать»); `true` — отправлено на печать.
typedef TransactionsDocumentPrinter = Future<bool> Function(OrderDocumentFile file);

/// Принтер; `null` — «Печать» скрыта.
final transactionsDocumentPrinterProvider = Provider<TransactionsDocumentPrinter?>((ref) => null);
