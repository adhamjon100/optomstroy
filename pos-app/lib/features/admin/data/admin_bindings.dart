// Привязка портов фичи admin к реализациям data (06 §6.14, L-8). Подключается в
// `app/di/overrides.dart`: `final appOverrides = <Override>[...adminOverrides];` — единственное
// место вне фичи, которому разрешён импорт `features/admin/data/**` (FL-06).
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/data/settings/dio_admin_settings_repository.dart';
import 'package:optomstroy/features/admin/data/users/dio_admin_users_repository.dart';
import 'package:optomstroy/features/admin/data/users/dio_step_up_gateway.dart';

final List<Override> adminOverrides = <Override>[
  adminUsersRepositoryProvider.overrideWith((ref) => DioAdminUsersRepository(ref.watch(dioProvider))),
  adminStepUpGatewayProvider.overrideWith((ref) => DioStepUpGateway(ref.watch(dioProvider))),
  // Этап G (основа): SCR-46 лимиты скидок и настройки, SCR-47 аудит.
  adminSettingsRepositoryProvider.overrideWith((ref) => DioAdminSettingsRepository(ref.watch(dioProvider))),
  auditLogRepositoryProvider.overrideWith((ref) => DioAuditLogRepository(ref.watch(dioProvider))),
];
