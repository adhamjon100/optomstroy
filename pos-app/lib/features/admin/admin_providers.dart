// Публичный контракт фичи admin (06 §6.14; FL-07: без своей data/** и presentation/**).
//
// Реализации портов подключает композиционный корень `app/di/overrides.dart`
// списком `adminOverrides` из `data/admin_bindings.dart` (L-8, FL-06).
// Порт step-up — [adminStepUpPrompterProvider]: core/session (StepUpDialog, RM-D-007/009)
// переопределяет его своим диалогом; пока он `null`, экран использует резервный диалог фичи.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/features/admin/domain/audit/audit_log.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings_repository.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_repository.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

/// Порт данных SCR-45. Реализация — `DioAdminUsersRepository` (data), подключается `adminOverrides`.
final adminUsersRepositoryProvider = Provider<AdminUsersRepository>(
  (ref) => throw UnimplementedError('adminUsersRepositoryProvider: подключите adminOverrides в app/di/overrides.dart'),
);

/// `POST /auth/step-up` для резервного диалога фичи. Реализация — `DioStepUpGateway` (data).
final adminStepUpGatewayProvider = Provider<StepUpGateway>(
  (ref) => throw UnimplementedError('adminStepUpGatewayProvider: подключите adminOverrides в app/di/overrides.dart'),
);

/// Показать StepUpDialog и вернуть токен (`null` — пользователь отменил).
///
/// Контракт для core/session: диалог сам вызывает `POST /auth/step-up` с `challenge.operation`
/// без изменений, показывает только методы `challenge.allowedMethods` (R1: `pin`, `otp`; кнопки
/// биометрии нет), считает попытки PIN только по `attemptsLeft` сервера, при `PIN_LOCKED` и
/// `pin_not_set` предлагает OTP; на compact — нижний лист (RM-D-014 п.5).
typedef AdminStepUpPrompter = Future<StepUpGrant?> Function(BuildContext context, StepUpChallenge challenge);

/// Порт StepUpDialog из core/session; `null` — резервный диалог фичи (`AdminStepUpDialog`).
final adminStepUpPrompterProvider = Provider<AdminStepUpPrompter?>((ref) => null);

/// Режим клиента: вкладка «Привязки клиентов» видна `admin` при `true` или непустом списке (UI-45-001).
///
/// Источник — `GET /settings/public` `features.customerSelfService` (08 §4.23.1; RM-D-015, FA-08):
/// [publicCustomerSelfServiceProvider]; пока ответа сервера нет — флаг сборки
/// `FEATURE_CUSTOMER_SELF_SERVICE` (по умолчанию `true`, ядро §24.2).
final adminCustomerSelfServiceProvider = Provider<bool>((ref) => ref.watch(publicCustomerSelfServiceProvider));

/// Порт SCR-46 (лимиты скидок, настройки приложения; этап G). Реализация — `DioAdminSettingsRepository` (data).
final adminSettingsRepositoryProvider = Provider<AdminSettingsRepository>(
  (ref) =>
      throw UnimplementedError('adminSettingsRepositoryProvider: подключите adminOverrides в app/di/overrides.dart'),
);

/// Порт SCR-47 (журнал аудита; этап G). Реализация — `DioAuditLogRepository` (data).
final auditLogRepositoryProvider = Provider<AuditLogRepository>(
  (ref) => throw UnimplementedError('auditLogRepositoryProvider: подключите adminOverrides в app/di/overrides.dart'),
);
