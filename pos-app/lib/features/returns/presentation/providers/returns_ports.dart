// Точки подключения SCR-39 к сессии, сети, флагам и step-up без межфичевого импорта презентации (06 §6.1: returns
// зависит только от orders, cashier, customers — и только через их domain/** и *_providers.dart, FL-03). Значения по
// умолчанию безопасны (fail-closed): роль неизвестна — только просмотр, действия скрыты. Корень (`app/di/overrides.dart`,
// интегратор) подставляет роль и пользователя сессии так же, как `ordersViewerProvider` / `catalogViewerRoleProvider`;
// в тестах — `overrideWithValue(...)`.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_controller.dart'
    show sessionControllerProvider, stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' show StepUpChallenge, StepUpCoordinator;
import 'package:optomstroy/features/returns/returns_providers.dart';
import 'package:uuid/uuid.dart';

/// Кто работает с заявкой: роль и пользователь сессии (11 §4.3–§4.4, `contracts/rbac/permissions.yaml`). Кнопки —
/// подсказка, не защита: права и object-level правило 11 SEC-030 (г) проверяет сервер.
@immutable
final class ReturnsViewer {
  /// Создаёт описание зрителя.
  const ReturnsViewer({this.role, this.userId});

  /// Роль сессии; `null` — неизвестна: только просмотр.
  final RoleCode? role;

  /// `sub` пользователя (чужой черновик — баннер «Черновик сотрудника {name}», CASH-007).
  final String? userId;

  /// `return.create` / `return.submit` — создание, правка, удаление и отправка черновика.
  bool get canCreate => role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin;

  /// `return.approve` — «Согласовать» / «Отклонить», отправка сверх порога (S!).
  bool get canApprove => role == RoleCode.seniorSeller || role == RoleCode.admin;

  @override
  bool operator ==(Object other) => other is ReturnsViewer && other.role == role && other.userId == userId;

  @override
  int get hashCode => Object.hash(role, userId);
}

/// Зритель SCR-39. По умолчанию — пользователь сессии без роли (кроме `customer` по виду пользователя): только
/// просмотр; роль из профиля входа подставляет корень.
final returnsViewerProvider = Provider<ReturnsViewer>((ref) {
  final UserKind? kind = ref.watch(sessionControllerProvider.select((s) => s.userKind));
  final String? userId = ref.watch(sessionControllerProvider.select((s) => s.userId));
  return ReturnsViewer(role: kind == UserKind.customer ? RoleCode.customer : null, userId: userId);
});

/// Сеть: заявка только онлайн (D-32, DATA-254) — офлайн/сервер недоступен ⇒ сохранение и отправка `disabled`.
final returnsOnlineProvider = Provider<bool>((ref) {
  final OnlineStatus? s = ref.watch(onlineStatusProvider).value;
  return s != OnlineStatus.offline && s != OnlineStatus.serverDown;
});

/// Модуль выключен сервером (`features.returnsFromPos=false`, 10 RET-012, AC-UI-39-010): экран показывает «Возвраты
/// оформляются в 1С». До первого ответа `GET /settings/public` флаг неизвестен (GQ-FEFND-09) — экран открывается,
/// решение за сервером.
final returnsScreenDisabledProvider = Provider<bool>((ref) {
  if (ref.watch(returnsEnabledProvider)) return false;
  return ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.fromServer));
});

/// Новый `Idempotency-Key` (P-IDEMP; ключ живёт только в памяти, 07 DATA-263).
final returnsKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Итог step-up до запроса: [cancelled] — пользователь закрыл `StepUpDialog` (запрос не отправляется);
/// [token] `null` без отмены — диалог не смонтирован, step-up выполнит AuthInterceptor по `403 STEP_UP_REQUIRED`.
typedef ReturnsStepUpResult = ({bool cancelled, String? token});

/// Step-up операции (`return.submit`, `return.approve`; 08 §2.12).
typedef ReturnsStepUp = Future<ReturnsStepUpResult> Function(String operation);

/// По умолчанию — `StepUpCoordinator` core/session (StepUpDialog: PIN / код из SMS, без биометрии — ядро §19.3).
final returnsStepUpProvider = Provider<ReturnsStepUp>((ref) {
  return (String operation) async {
    final StepUpCoordinator coordinator = ref.read(stepUpCoordinatorProvider);
    if (!coordinator.hasPresenter) return (cancelled: false, token: null);
    final String? token = await coordinator.obtain(StepUpChallenge(operation: operation));
    return (cancelled: token == null, token: token);
  };
});

/// Операции step-up SCR-39 (`stepUp.operation`, 11 §4.3 №68, №74).
abstract final class ReturnsStepUpOperations {
  /// Отправка заявки (`POST /returns/{id}/submit`).
  static const String submit = 'return.submit';

  /// Согласование / отклонение (`POST /returns/{id}/accept|reject`).
  static const String approve = 'return.approve';
}
