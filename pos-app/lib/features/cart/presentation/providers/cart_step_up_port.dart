// Step-up для корзины (02 UI-20-033 «Подтвердить скидку {p} %»: `discount.approve.over_limit`, S!) — координатор
// core/session (StepUpDialog SCR-90); в тестах — `overrideWithValue`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' show StepUpChallenge;

/// Получить step-up токен операции; `null` — отмена.
typedef CartStepUp = Future<String?> Function(String operation);

/// Step-up корзины.
final cartStepUpProvider = Provider<CartStepUp>((ref) {
  final coordinator = ref.watch(stepUpCoordinatorProvider);
  return (String operation) => coordinator.obtain(StepUpChallenge(operation: operation));
});
