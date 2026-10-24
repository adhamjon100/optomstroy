// Публичный контракт фичи settings — SCR-42 «Настройки» (06 §6.14; FL-07: без своей data/** и presentation/**).
//
// Реализации портов подключает композиционный корень `app/di/overrides.dart` списком `settingsBindings`
// (`data/settings_bindings.dart`). Точки расширения секций, которыми владеют другие фичи (DAG 06 §6.1 не
// разрешает settings импортировать scan/печать): [settingsScannerSectionProvider] — секция «Сканер штрихкодов»
// (`ScannerSettingsSection` фичи scan, 02 UI-42-011/012/018/019), [settingsPrinterSectionProvider] — «Принтер»
// (UI-42-014/020…022). Пока провайдер `null`, секция в списке не показывается.
//
// [displayPreferencesProvider] — локальные настройки отображения (плотность, размер текста, уменьшение
// анимаций); их применяет корень приложения (тема, `TextScaler`, `DsMotion.reduceMotion`).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';

/// Устройства и сессии; реализация — `settingsBindings` (до подключения — [UnboundSettingsRepository]: ошибка).
final deviceSessionsRepositoryProvider = Provider<DeviceSessionsRepository>((ref) => const UnboundSettingsRepository());

/// Защита входа; реализация — `settingsBindings` (до подключения — [UnboundSettingsRepository]: ошибка).
final loginProtectionRepositoryProvider = Provider<LoginProtectionRepository>(
  (ref) => const UnboundSettingsRepository(),
);

/// Хранилище настроек отображения; по умолчанию — память процесса.
final displayPreferencesRepositoryProvider = Provider<DisplayPreferencesRepository>(
  (ref) => MemoryDisplayPreferencesRepository(),
);

/// «О приложении»; по умолчанию — без метаданных сборки.
final appAboutSourceProvider = Provider<AppAboutSource>((ref) => const _UnboundAboutSource());

/// Построитель секции другой фичи внутри SCR-42.
typedef SettingsSectionBuilder = Widget Function(BuildContext context);

/// Секция «Сканер штрихкодов» (фича scan). `null` — секция скрыта.
final settingsScannerSectionProvider = Provider<SettingsSectionBuilder?>((ref) => null);

/// Секция «Принтер» (печать, D-27). `null` — секция скрыта.
final settingsPrinterSectionProvider = Provider<SettingsSectionBuilder?>((ref) => null);

/// `Settings.scanAddsToCart` текущего пользователя (UI-42-019; ядро §19.4) — для режима скана в каталоге и SCR-17:
/// загружается после входа (`GET /me`), обновляется переключателем SCR-42. `null` — не загружено или сервер не
/// прислал значение (действует умолчание по роли: `cashier` — вкл.). Корень подставляет его в `scanAddsToCartProvider`.
final userScanAddsToCartProvider = NotifierProvider<UserScanAddsToCart, bool?>(UserScanAddsToCart.new);

/// Хранилище [userScanAddsToCartProvider]: сбрасывается при смене пользователя сессии.
class UserScanAddsToCart extends Notifier<bool?> {
  @override
  bool? build() {
    final String? userId = ref.watch(sessionControllerProvider.select((s) => s.userId));
    if (userId == null) return null;
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(_load());
    });
    return null;
  }

  Future<void> _load() async {
    final Result<LoginProtectionState> res = await ref.read(loginProtectionRepositoryProvider).load();
    if (!ref.mounted) return;
    if (res case Success<LoginProtectionState>(:final value)) state = value.scanAddsToCart;
  }

  /// Значение сервера изменилось (SCR-42: загрузка, переключатель «Сразу добавлять в корзину»).
  void set(bool? value) => state = value;
}

/// Пользователь SCR-42: вид из сессии (claims) или профиля входа, главная роль — из профиля входа.
final settingsViewerProvider = Provider<SettingsViewer>((ref) {
  final UserKind? sessionKind = ref.watch(sessionControllerProvider.select((s) => s.userKind));
  final AuthSessionState auth = ref.watch(authSessionProvider);
  return SettingsViewer(kind: sessionKind ?? auth.profile.kind, primaryRole: auth.profile.primaryRole);
});

/// Сеть есть (серверные действия SCR-42 офлайн недоступны — `settings_offline_disabled`).
/// `unknown` считается «онлайн»: окончательно решает исход запроса.
final settingsOnlineProvider = Provider<bool>((ref) {
  final OnlineStatus status = ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown;
  return status == OnlineStatus.online || status == OnlineStatus.unknown;
});

/// Настройки отображения устройства (применяются сразу ко всему приложению).
final displayPreferencesProvider = NotifierProvider<DisplayPreferencesController, DisplayPreferences>(
  DisplayPreferencesController.new,
);

final class DisplayPreferencesController extends Notifier<DisplayPreferences> {
  @override
  DisplayPreferences build() {
    final DisplayPreferencesRepository repo = ref.watch(displayPreferencesRepositoryProvider);
    unawaited(
      repo.load().then((DisplayPreferences loaded) {
        if (ref.mounted) state = loaded;
      }, onError: (Object _) {}),
    );
    return DisplayPreferences.defaults;
  }

  /// Применить сразу и сохранить.
  Future<void> update(DisplayPreferences value) async {
    state = value;
    await ref.read(displayPreferencesRepositoryProvider).save(value);
  }
}

/// Хранилище настроек отображения в памяти (до подключения drift / в тестах).
final class MemoryDisplayPreferencesRepository implements DisplayPreferencesRepository {
  MemoryDisplayPreferencesRepository([this._value = DisplayPreferences.defaults]);

  DisplayPreferences _value;

  @override
  Future<DisplayPreferences> load() async => _value;

  @override
  Future<void> save(DisplayPreferences value) async => _value = value;
}

final class _UnboundAboutSource implements AppAboutSource {
  const _UnboundAboutSource();

  @override
  AppAboutInfo current() => const AppAboutInfo(appVersion: '—');
}

/// Порты до подключения `settingsBindings`: каждый вызов — `UnknownFailure(settings_repository_unbound)`,
/// экран показывает `ErrorState` вместо падения (маршрутные тесты без привязок).
final class UnboundSettingsRepository implements DeviceSessionsRepository, LoginProtectionRepository {
  const UnboundSettingsRepository();

  static const Failure _unbound = UnknownFailure(cause: 'settings_repository_unbound');

  @override
  Future<Result<List<DeviceSession>>> list() async => const FailureResult<List<DeviceSession>>(_unbound);

  @override
  Future<Result<void>> revoke(String sessionId) async => const FailureResult<void>(_unbound);

  @override
  Future<Result<DeviceSession>> rename(String sessionId, String deviceName) async =>
      const FailureResult<DeviceSession>(_unbound);

  @override
  Future<void> logoutCurrent() async {}

  @override
  Future<Result<void>> logoutAll() async => const FailureResult<void>(_unbound);

  @override
  Future<Result<LoginProtectionState>> load() async => const FailureResult<LoginProtectionState>(_unbound);

  @override
  Future<Result<void>> changePin(String newPin) async => const FailureResult<void>(_unbound);

  @override
  Future<Result<void>> removePin() async => const FailureResult<void>(_unbound);

  @override
  Future<bool> stepUpForPin({required bool otpOnly}) async => false;

  @override
  Future<BiometricToggleOutcome> enableBiometrics(BiometricPromptCopy prompt) async => BiometricToggleOutcome.failed;

  @override
  Future<BiometricToggleOutcome> disableBiometrics() async => BiometricToggleOutcome.failed;

  @override
  Future<Result<int>> setIdleLockMinutes(int minutes) async => const FailureResult<int>(_unbound);

  @override
  Future<Result<Map<String, Object?>>> patchSettings(Map<String, Object?> patch) async =>
      const FailureResult<Map<String, Object?>>(_unbound);
}
