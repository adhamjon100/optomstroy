import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';

/// Маршрут SCR-01 (`/auth/phone`): вход по номеру телефона ([PhoneScreen], RM-D-007).
///
/// Класс сохранён для `app/router/routes.dart` (каркас RM-C-002) и тестов RM-C-014: ключи
/// экрана и маркеры `GET /health` прежние. Причина возврата (`reason`) и адрес возврата
/// (`returnTo`) читаются из query текущего маршрута.
class NoSessionScreen extends StatelessWidget {
  /// Создаёт экран.
  const NoSessionScreen({super.key});

  /// Ключ корневого виджета экрана (smoke-тест и integration_test RM-C-014).
  static const Key screenKey = Key('scr-01-no-session');

  /// Маркер: `GET /health` ещё выполняется.
  static const Key healthPendingKey = PhoneScreen.healthPendingKey;

  /// Маркер: `GET /health` → 200 `{status: ok}`.
  static const Key healthOkKey = PhoneScreen.healthOkKey;

  /// Строка «Сервер недоступен».
  static const Key healthDownKey = PhoneScreen.healthDownKey;

  @override
  Widget build(BuildContext context) {
    final Map<String, String> query = GoRouter.maybeOf(context)?.state.uri.queryParameters ?? const <String, String>{};
    return KeyedSubtree(
      key: screenKey,
      child: PhoneScreen(
        entryReason: AuthEntryReason.tryParse(query[AuthPaths.reasonParam]),
        returnTo: AuthPaths.safeReturnTo(query[AuthPaths.returnToParam]),
      ),
    );
  }
}
