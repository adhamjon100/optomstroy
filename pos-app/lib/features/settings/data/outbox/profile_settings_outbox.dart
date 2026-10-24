// Outbox `profile.settings` (EQ-DREST-07, перенос этапа E; 07 §11.2 — тип `outbox_actions`; 02 SCR-42.4 «Общие
// правила сохранения», SCR-42.7 «Устаревшие данные» (а)): изменение серверных настроек `Settings` (08 §3.14) без
// сети применяется локально сразу (optimistic) и ставится в очередь; при появлении сети — `PUT /me/settings`
// полным объектом с `rowVersion` кэша и `Idempotency-Key` записи; `409 VERSION_CONFLICT` — взять `current`,
// повторно наложить только изменённые поля и отправить ещё раз (одна попытка), иначе запись `dead` (серверное
// значение остаётся, UI покажет его при следующем `GET /me`).
//
// Полезная нагрузка (ПДн и секретов нет): `{settings: <тело PUT>, patch: <изменённые поля>}`.
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/repositories/login_protection_repository_impl.dart';

/// Тип записи `outbox_actions.type` (07 §11.2).
const String profileSettingsOutboxType = 'profile.settings';

/// Поставить изменение настроек в очередь: `true` — запись создана.
typedef ProfileSettingsEnqueue = Future<bool> Function(Map<String, Object?> payload);

/// Полезная нагрузка `profile.settings`.
final class ProfileSettingsPayload {
  const ProfileSettingsPayload({required this.settings, required this.patch});

  /// Разбор `payload_json`; неполная запись → `null` (`dead`).
  static ProfileSettingsPayload? tryParse(Map<String, Object?> json) {
    final Object? settings = json['settings'];
    final Object? patch = json['patch'];
    if (settings is! Map || patch is! Map || patch.isEmpty) return null;
    return ProfileSettingsPayload(
      settings: Map<String, Object?>.from(settings),
      patch: Map<String, Object?>.from(patch),
    );
  }

  /// Тело `PUT /me/settings`: настройки кэша `/me` (с его `rowVersion`) + [patch].
  final Map<String, Object?> settings;

  /// Изменённые поля — повторно накладываются на `current` при `409`.
  final Map<String, Object?> patch;

  Map<String, Object?> toJson() => <String, Object?>{'settings': settings, 'patch': patch};
}

/// Обработчик `profile.settings` (регистрирует корень в `outboxHandlersProvider`).
final class ProfileSettingsOutboxHandler implements OutboxActionHandler {
  ProfileSettingsOutboxHandler(this._api);

  final SettingsApi Function() _api;

  @override
  Set<String> get types => const <String>{profileSettingsOutboxType};

  @override
  Future<OutboxOutcome> handle(OutboxAction action) async {
    final ProfileSettingsPayload? payload = ProfileSettingsPayload.tryParse(action.payload);
    if (payload == null) return OutboxOutcome.dead;
    final SettingsApi api = _api();
    // Фоновая отправка — профиль автоповтора background (08 §2.10), ключ записи (повтор не создаёт дублей).
    Result<Map<String, Object?>> saved = await ErrorMapper.guard(
      () => api.putSettings(payload.settings, idempotencyKey: action.idempotencyKey, retry: RetryProfile.background),
    );
    if (saved case FailureResult<Map<String, Object?>>(failure: ConflictFailure(:final details))) {
      final Object? current = details['current'];
      if (current is! Map) return OutboxOutcome.dead;
      final Map<String, Object?> body = LoginProtectionRepositoryImpl.settingsBody(
        Map<String, Object?>.from(current),
        payload.patch,
      );
      // Новое тело — новый ключ (ключ записи уже связан с телом, получившим 409).
      saved = await ErrorMapper.guard(() => api.putSettings(body, retry: RetryProfile.background));
      if (saved case FailureResult<Map<String, Object?>>(failure: ConflictFailure())) return OutboxOutcome.dead;
    }
    return switch (saved) {
      Success<Map<String, Object?>>() => OutboxOutcome.done,
      FailureResult<Map<String, Object?>>(:final failure) => outboxOutcomeOf(failure),
    };
  }
}
