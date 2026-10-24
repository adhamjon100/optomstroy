// Состояние версии клиента (D-46, RM-C-015, 08 §2.11): ответ 426 → блокирующий SCR-90
// «Требуется обновление»; версия ниже `X-Recommended-App-Version` → мягкий баннер.
// Последние увиденные значения пишутся в `app_meta.min_app_version_seen` /
// `recommended_app_version_seen` (07 §11.2) через [AppVersionSink].
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/utils/app_version.dart';

enum AppVersionStatus {
  /// Ограничений нет.
  ok,

  /// Доступно обновление — мягкий баннер, работа продолжается.
  updateRecommended,

  /// Требуется обновление — блокирующий экран SCR-90.
  updateRequired,
}

@immutable
final class AppVersionState {
  const AppVersionState({required this.status, this.minimum, this.recommended, this.storeUrl});

  static const AppVersionState initial = AppVersionState(status: AppVersionStatus.ok);

  final AppVersionStatus status;

  /// Минимальная версия для платформы клиента (как пришла от сервера).
  final String? minimum;

  /// Рекомендуемая версия для платформы клиента.
  final String? recommended;

  /// Ссылка на обновление из тела 426 (`storeUrl`, 08 §2.4); `null` — SCR-90 показывает инструкцию без ссылки.
  final String? storeUrl;

  @override
  bool operator ==(Object other) =>
      other is AppVersionState &&
      other.status == status &&
      other.minimum == minimum &&
      other.recommended == recommended &&
      other.storeUrl == storeUrl;

  @override
  int get hashCode => Object.hash(status, minimum, recommended, storeUrl);

  @override
  String toString() => 'AppVersionState(${status.name}, min: $minimum, recommended: $recommended)';
}

/// Запись `app_meta` (ключ → значение).
typedef AppVersionSink = Future<void> Function(String key, String value);

final class AppVersionController extends ValueNotifier<AppVersionState> {
  AppVersionController({required String currentVersion, required this.platform, AppVersionSink? sink})
    : _current = AppVersion.tryParse(currentVersion),
      _sink = sink,
      super(AppVersionState.initial);

  /// Ключи `app_meta` (07 §11.2).
  static const String minSeenKey = 'min_app_version_seen';
  static const String recommendedSeenKey = 'recommended_app_version_seen';

  final AppVersion? _current;

  /// Значение `X-Platform` клиента (`android|windows|ios`) или `null`.
  final String? platform;
  final AppVersionSink? _sink;

  /// Заголовки любого ответа (2xx и ошибки).
  Future<void> onHeaders({String? minHeader, String? recommendedHeader}) async {
    final minimum = AppVersion.forPlatform(minHeader, platform);
    final recommended = AppVersion.forPlatform(recommendedHeader, platform);
    if (minimum == null && recommended == null) return;
    final current = _current;
    // Блокировка по 426 не снимается заголовками следующих ответов (снимается только перезапуском новой версии).
    if (value.status == AppVersionStatus.updateRequired && (current == null || minimum == null || current < minimum)) {
      return;
    }
    final AppVersionStatus status;
    if (current != null && minimum != null && current < minimum) {
      status = AppVersionStatus.updateRequired;
    } else if (current != null && recommended != null && current < recommended) {
      status = AppVersionStatus.updateRecommended;
    } else {
      status = AppVersionStatus.ok;
    }
    value = AppVersionState(status: status, minimum: minimum?.toString(), recommended: recommended?.toString());
    await _persist(minimum, recommended);
  }

  /// Ответ `426 APP_UPDATE_REQUIRED`: блокировка независимо от разбора версий.
  /// [storeUrl] — поле тела 426 (только https, иначе игнорируется).
  Future<void> onUpdateRequired({String? minHeader, String? minVersionBody, String? storeUrl}) async {
    final minimum = AppVersion.forPlatform(minHeader, platform) ?? AppVersion.forPlatform(minVersionBody, platform);
    final url = storeUrl != null && Uri.tryParse(storeUrl)?.isScheme('https') == true ? storeUrl : null;
    value = AppVersionState(
      status: AppVersionStatus.updateRequired,
      minimum: minimum?.toString(),
      recommended: value.recommended,
      storeUrl: url,
    );
    await _persist(minimum, null);
  }

  Future<void> _persist(AppVersion? minimum, AppVersion? recommended) async {
    final sink = _sink;
    if (sink == null) return;
    if (minimum != null) await sink(minSeenKey, minimum.toString());
    if (recommended != null) await sink(recommendedSeenKey, recommended.toString());
  }
}
