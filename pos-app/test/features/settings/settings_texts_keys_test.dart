// EQ-DREST-01, EQ-DREST-03 (03 §16.7): самоназвания языков SCR-42 и текст ошибки загрузки списка сессий.
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';

void main() {
  final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

  test('языки — самоназвания, неизвестный код — прописными', () {
    expect(SettingsTexts.languageName(l10n, 'ru'), l10n.settings_language_ru);
    expect(SettingsTexts.languageName(l10n, 'ky'), l10n.settings_language_ky);
    expect(SettingsTexts.languageName(l10n, 'en'), l10n.settings_language_en);
    expect(SettingsTexts.languageName(l10n, 'uz'), 'UZ');
  });

  test('ошибка загрузки сессий: нет сети — текст сети, прочее — settings_sessions_load_error', () {
    expect(
      SettingsTexts.sessionsLoadFailure(l10n, const NetworkFailure(NetworkFailureKind.offline)),
      l10n.auth_error_network,
    );
    expect(
      SettingsTexts.sessionsLoadFailure(l10n, const NetworkFailure(NetworkFailureKind.serverUnavailable)),
      l10n.settings_sessions_load_error,
    );
    expect(SettingsTexts.sessionsLoadFailure(l10n, const UnknownFailure()), l10n.settings_sessions_load_error);
  });
}
