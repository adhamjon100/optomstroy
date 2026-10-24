// «Устройства и сессии» SCR-42 (08 §4.1.5–§4.1.6; 09 §8.4; UI-42-013, UI-42-015…017).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';

/// Выход текущей сессии и «выйти везде» выполняет core/session (SessionController): очистка секретов и
/// локальных данных владельца — там (09 §8.6). `logoutAll` возвращает ошибку или `null` (успех).
typedef SessionLogout = Future<void> Function();
typedef SessionLogoutAll = Future<Failure?> Function();

final class DeviceSessionsRepositoryImpl implements DeviceSessionsRepository {
  DeviceSessionsRepositoryImpl(this._api, {required SessionLogout logout, required SessionLogoutAll logoutAll})
    : _logout = logout,
      _logoutAll = logoutAll;

  final SettingsApi _api;
  final SessionLogout _logout;
  final SessionLogoutAll _logoutAll;

  /// `Session` → [DeviceSession]; обязательные поля — `id`, `deviceId`, `isCurrent`.
  static DeviceSession sessionFromJson(Map<String, Object?> j) {
    final Object? id = j['id'];
    final Object? deviceId = j['deviceId'];
    if (id is! String || deviceId is! String) throw const FormatException('Session: нет id/deviceId');
    DateTime? at(String key) {
      final Object? v = j[key];
      return v is String ? DateTime.tryParse(v)?.toUtc() : null;
    }

    String? str(String key) {
      final Object? v = j[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    return DeviceSession(
      id: id,
      deviceId: deviceId,
      isCurrent: j['isCurrent'] == true,
      deviceName: str('deviceName'),
      platform: DevicePlatform.tryParse(str('platform')),
      appVersion: str('appVersion'),
      kind: SessionKind.tryParse(str('kind')),
      createdAt: at('createdAt'),
      lastUsedAt: at('lastUsedAt'),
      ipMasked: str('ipLast'),
    );
  }

  /// Порядок: текущая сессия первой, далее — по последней активности (новые выше).
  static List<DeviceSession> ordered(Iterable<DeviceSession> items) {
    final List<DeviceSession> list = items.toList();
    list.sort((DeviceSession a, DeviceSession b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      final DateTime ea = a.lastUsedAt ?? a.createdAt ?? DateTime.utc(1970);
      final DateTime eb = b.lastUsedAt ?? b.createdAt ?? DateTime.utc(1970);
      return eb.compareTo(ea);
    });
    return list;
  }

  @override
  Future<Result<List<DeviceSession>>> list() =>
      ErrorMapper.guard(() async => ordered((await _api.sessions()).map(sessionFromJson)));

  @override
  Future<Result<void>> revoke(String sessionId) async {
    final Result<void> result = await ErrorMapper.guard(() => _api.revokeSession(sessionId));
    // `404 NOT_FOUND` — сессия уже завершена: строка удаляется без ошибки (02 SCR-42.4).
    if (result case FailureResult<void>(failure: ServerFailure(status: 404))) return const Success<void>(null);
    return result;
  }

  @override
  Future<Result<DeviceSession>> rename(String sessionId, String deviceName) =>
      ErrorMapper.guard(() async => sessionFromJson(await _api.renameSession(sessionId, deviceName)));

  @override
  Future<void> logoutCurrent() => _logout();

  @override
  Future<Result<void>> logoutAll() async {
    final Failure? failure = await _logoutAll();
    return failure == null ? const Success<void>(null) : FailureResult<void>(failure);
  }
}
