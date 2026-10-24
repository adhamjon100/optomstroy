// Статус сессии для маршрутизации (authGuard, Splash) — контракт app/router и features/splash
// (L-9: presentation читает только read-only провайдеры core). Реализация — SessionController
// (core/session/session_controller.dart, RM-D-009): восстановление при холодном старте, вход,
// выход, завершение сервером; блокировка (SCR-08) — отдельное измерение `SessionState.lock`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/session/session_controller.dart';

/// Состояние сессии для маршрутизации (authGuard, Splash).
enum SessionStatus {
  /// Сессия ещё восстанавливается (Splash).
  unknown,

  /// Валидной сессии нет — вход по телефону (SCR-01).
  unauthenticated,

  /// Сессия действительна (возможно, экран заблокирован — SCR-08 overlay поверх).
  authenticated,
}

/// Результат восстановления сессии при холодном старте и последующие изменения статуса
/// (вход, выход, `SESSION_REVOKED`).
final sessionStatusProvider = FutureProvider<SessionStatus>((ref) async {
  // Сначала — восстановление (однократное, результат кэшируется контроллером), затем подписка на статус:
  // смена статуса пересчитывает провайдер без повторного чтения secure storage.
  await ref.watch(sessionControllerProvider.notifier).restore();
  return ref.watch(sessionControllerProvider.select((s) => s.status));
});
