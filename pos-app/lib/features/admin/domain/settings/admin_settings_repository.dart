// Порт SCR-46 (08 §4.18.5–§4.18.6). Изменения — `PUT` целиком с `rowVersion` (`VERSION_CONFLICT` — перечитать),
// step-up обязателен (`STEP_UP_REQUIRED` → StepUpDialog; токен — AuthInterceptor или явный [stepUpToken]).
// Только онлайн. Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';

abstract interface class AdminSettingsRepository {
  /// `GET /admin/settings`.
  Future<Result<AdminSettings>> settings();

  /// `PUT /admin/settings`.
  Future<Result<AdminSettings>> updateSettings(
    AdminSettingsValues values, {
    required int rowVersion,
    String? idempotencyKey,
    String? stepUpToken,
  });

  /// `GET /admin/discount-limits`.
  Future<Result<AdminDiscountLimits>> discountLimits();

  /// `PUT /admin/discount-limits`.
  Future<Result<AdminDiscountLimits>> updateDiscountLimits(
    AdminDiscountLimits limits, {
    String? idempotencyKey,
    String? stepUpToken,
  });
}
