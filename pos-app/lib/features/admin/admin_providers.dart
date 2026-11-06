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
import 'package:optomstroy/features/admin/domain/tablets/admin_tablets_repository.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
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

/// Порт SCR-54 «Планшеты магазина» (08 §4.18.11–§4.18.15; ADR-115). Реализация — `DioAdminTabletsRepository` (data).
final adminTabletsRepositoryProvider = Provider<AdminTabletsRepository>(
  (ref) =>
      throw UnimplementedError('adminTabletsRepositoryProvider: подключите adminOverrides в app/di/overrides.dart'),
);

/// Это устройство становится планшетом магазина (SCR-54, FLOW-043.S4–S6, A2; 09 §8.9 п. 1, п. 6). Реализацию поверх
/// `SessionController` (core/session) привязывает корень `app/di/overrides.dart`.
abstract interface class AdminKioskDevice {
  /// `store_tablets.id` из признака планшета на устройстве, если он сохранился — предвыбор UI-54-013.
  Future<String?> knownTabletId();

  /// Перед `POST /admin/store-tablets` и `…/reconnect`: сервер отзывает сессию администратора на устройстве в той же
  /// транзакции — до «Готово» на диалоге аварийного кода её конец не уводит на SCR-01 и не стирает ответ.
  void holdSession();

  /// Подключение не состоялось (ошибка, отмена): сессия администратора — как обычно.
  void releaseSession();

  /// «Готово» (UI-54-014): данные администратора на устройстве удаляются, признак, хэш аварийного кода и токены
  /// планшета сохраняются, закрепление включается, приложение уходит в режим планшета (SCR-51).
  Future<void> become(KioskEnrollment enrollment);
}

/// Порт [AdminKioskDevice]; `null` — устройство планшетом не становится (подключение и «Подключить заново» скрыты).
final adminKioskDeviceProvider = Provider<AdminKioskDevice?>((ref) => null);

/// `features.storeTablet` (env `KIOSK_MODE`, `GET /settings/public`; fail-closed до ответа сервера): подключение и
/// «Подключить заново» — только при `true`; список, «Изменить» и «Отключить планшет» — всегда (ADR-115 п. 28).
final adminKioskEnabledProvider = Provider<bool>((ref) => ref.watch(kioskEnabledProvider));

/// `recommendedAppVersion` (`SemVerByPlatform`) из `GET /settings/public` — «Нужна новая версия приложения» (UI-54-009).
final adminRecommendedAppVersionProvider = Provider<String?>(
  (ref) => ref.watch(publicSettingsProvider.select((PublicSettingsSnapshot s) => s.settings.recommendedAppVersion)),
);
