// Тексты SCR-42 из ARB (contracts/l10n; 02 SCR-42.8; ключи, запрошенные реализацией, — 03 §16.7).
import 'package:intl/intl.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';

abstract final class SettingsTexts {
  /// Заголовок секции.
  static String section(AppLocalizations l10n, SettingsSection s) => switch (s) {
    SettingsSection.language => l10n.settings_section_language,
    SettingsSection.security => l10n.settings_section_security,
    SettingsSection.sessions => l10n.settings_section_sessions,
    SettingsSection.scanner => l10n.settings_section_scanner,
    SettingsSection.printer => l10n.settings_section_printer,
    SettingsSection.display => l10n.settings_section_display,
    SettingsSection.about => l10n.settings_section_about,
  };

  /// Подпись тумблера биометрии по платформе (UI-42-010).
  static String biometricLabel(AppLocalizations l10n, BiometricPlatformLabel p) => switch (p) {
    BiometricPlatformLabel.android => l10n.settings_bio_android,
    BiometricPlatformLabel.ios => l10n.settings_bio_ios,
    BiometricPlatformLabel.windows => l10n.settings_bio_windows,
  };

  /// Ошибка запроса (без технических подробностей).
  static String failure(AppLocalizations l10n, Failure f) => switch (f) {
    NetworkFailure(kind: NetworkFailureKind.timeout) => l10n.auth_error_timeout,
    NetworkFailure(kind: NetworkFailureKind.serverUnavailable) => l10n.ds_server_down,
    NetworkFailure() => l10n.auth_error_network,
    AuthFailure(reason: AuthReason.sessionRevoked) => l10n.auth_error_revoked,
    ConflictFailure(kind: ConflictKind.versionConflict) => l10n.settings_conflict,
    _ => l10n.settings_save_error,
  };

  /// Название платформы сессии (без ARB-ключей — EQ-SET-02: имена платформ не переводятся).
  static String platform(DevicePlatform? p) => switch (p) {
    DevicePlatform.android => 'Android',
    DevicePlatform.ios => 'iOS',
    DevicePlatform.windows => 'Windows',
    null => '—',
  };

  /// Самоназвание языка (02 SCR-42.2; ключи `settings_language_*` — 03 §16.7, EQ-DREST-01); неизвестный код —
  /// сам код прописными.
  static String languageName(AppLocalizations l10n, String code) => switch (code) {
    'ru' => l10n.settings_language_ru,
    'ky' => l10n.settings_language_ky,
    'en' => l10n.settings_language_en,
    _ => code.toUpperCase(),
  };

  /// Ошибка загрузки списка сессий (02 SCR-42.7, `ErrorState.inline`; EQ-DREST-03): нет сети — текст сети,
  /// прочее — `settings_sessions_load_error`.
  static String sessionsLoadFailure(AppLocalizations l10n, Failure f) => switch (f) {
    NetworkFailure(kind: NetworkFailureKind.offline) => l10n.auth_error_network,
    AuthFailure(reason: AuthReason.sessionRevoked) => l10n.auth_error_revoked,
    _ => l10n.settings_sessions_load_error,
  };

  /// `d MMM, HH:mm` по часам магазина Asia/Bishkek (02 §0.1), не пояса машины.
  static String dateTime(DateTime at, String locale) =>
      DateFormat('d MMM, HH:mm', locale).format(DsBishkekTime.wall(at));

  /// `d MMM y` (день магазина Asia/Bishkek).
  static String date(DateTime at, String locale) => DateFormat('d MMM y', locale).format(DsBishkekTime.wall(at));
}
