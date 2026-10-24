// Секции SCR-42 без сервера: «Язык» (UI-42-001), «Отображение» (UI-42-006/007/025), «О приложении» (UI-42-008).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// Ключи для тестов.
abstract final class BasicSectionKeys {
  static Key language(String code) => ValueKey<String>('settings-language-$code');
  static Key density(DisplayDensity d) => ValueKey<String>('settings-density-${d.name}');
  static Key textScale(TextScaleOption t) => ValueKey<String>('settings-text-scale-${t.name}');
  static const Key reduceMotion = ValueKey<String>('settings-reduce-motion');
  static const Key aboutVersion = ValueKey<String>('settings-about-version');
  static const Key aboutMin = ValueKey<String>('settings-about-min');
  static const Key aboutRecommended = ValueKey<String>('settings-about-recommended');
  static const Key aboutDevice = ValueKey<String>('settings-about-device');
  static const Key aboutLicenses = ValueKey<String>('settings-about-licenses');
  static const Key aboutSupport = ValueKey<String>('settings-about-support');
  static const Key aboutPrivacy = ValueKey<String>('settings-about-privacy');
}

/// «Язык»: русский выбран; ky/en видны неактивными с подписью «Скоро» (AC-UI-42-001, D-38).
class LanguageSection extends StatelessWidget {
  const LanguageSection({super.key});

  /// Языки ARB (03 §16.6); выбор доступен при покрытии ≥ 95 % — в R1 только `ru`.
  static const List<String> codes = <String>['ru', 'ky', 'en'];

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final String code in codes)
          AppRadio<String>(
            key: BasicSectionKeys.language(code),
            value: code,
            groupValue: 'ru',
            label: SettingsTexts.languageName(l10n, code),
            description: code == 'ru' ? null : l10n.settings_language_soon,
            onChanged: code == 'ru' ? (_) {} : null,
          ),
      ],
    );
  }
}

/// «Отображение»: плотность, размер текста, уменьшение анимаций — локально, применяются сразу.
class DisplaySection extends ConsumerWidget {
  const DisplaySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DisplayPreferences p = ref.watch(displayPreferencesProvider);
    final DisplayPreferencesController controller = ref.read(displayPreferencesProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(title: l10n.settings_density_label, padding: EdgeInsets.zero),
        for (final DisplayDensity d in DisplayDensity.values)
          AppRadio<DisplayDensity>(
            key: BasicSectionKeys.density(d),
            value: d,
            groupValue: p.density,
            label: switch (d) {
              DisplayDensity.auto => l10n.settings_density_auto,
              DisplayDensity.standard => l10n.settings_density_standard,
              DisplayDensity.compact => l10n.settings_density_compact,
            },
            onChanged: (DisplayDensity v) => unawaited(controller.update(p.copyWith(density: v))),
          ),
        SizedBox(height: context.space.s4),
        AppSectionHeader(title: l10n.settings_text_scale_label, padding: EdgeInsets.zero),
        for (final TextScaleOption t in TextScaleOption.values)
          AppRadio<TextScaleOption>(
            key: BasicSectionKeys.textScale(t),
            value: t,
            groupValue: p.textScale,
            label: switch (t) {
              TextScaleOption.system => l10n.settings_text_scale_system,
              TextScaleOption.large => l10n.settings_text_scale_large,
              TextScaleOption.xlarge => l10n.settings_text_scale_xlarge,
            },
            onChanged: (TextScaleOption v) => unawaited(controller.update(p.copyWith(textScale: v))),
          ),
        SizedBox(height: context.space.s4),
        AppSwitch(
          key: BasicSectionKeys.reduceMotion,
          value: p.reduceMotion,
          label: l10n.settings_reduce_motion,
          onChanged: (bool v) => unawaited(controller.update(p.copyWith(reduceMotion: v))),
        ),
      ],
    );
  }
}

/// «О приложении»: версия, минимальная/рекомендуемая версии, устройство, лицензии, поддержка.
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppAboutInfo info = ref.watch(appAboutSourceProvider).current();
    final PublicSettings settings = ref.watch(publicSettingsProvider.select((PublicSettingsSnapshot s) => s.settings));
    final String platform = info.platform == null ? '' : ' · ${SettingsTexts.platform(info.platform)}';
    final List<SupportContact> support = settings.supportContacts ?? const <SupportContact>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppListTile(
          key: BasicSectionKeys.aboutVersion,
          title: l10n.settings_about_version,
          subtitle: '${info.appVersion}$platform',
        ),
        AppListTile(
          key: BasicSectionKeys.aboutMin,
          title: l10n.settings_about_min_version,
          subtitle: info.minVersion ?? '—',
        ),
        AppListTile(
          key: BasicSectionKeys.aboutRecommended,
          title: l10n.settings_about_recommended_version,
          subtitle: info.recommendedVersion ?? '—',
        ),
        if (info.deviceIdSuffix != null)
          AppListTile(key: BasicSectionKeys.aboutDevice, title: l10n.settings_about_device_id(info.deviceIdSuffix!)),
        AppListTile(
          key: BasicSectionKeys.aboutLicenses,
          title: l10n.settings_about_licenses,
          showChevron: true,
          onTap: () => showLicensePage(context: context, applicationVersion: info.appVersion),
        ),
        AppListTile(
          key: BasicSectionKeys.aboutSupport,
          title: l10n.settings_about_support,
          subtitle: support.isEmpty
              ? '—'
              : support.map((SupportContact c) => c.label == null ? c.value : '${c.label}: ${c.value}').join(' · '),
        ),
        if (settings.privacyContact != null)
          AppListTile(
            key: BasicSectionKeys.aboutPrivacy,
            title: l10n.settings_about_privacy,
            subtitle: settings.privacyContact,
          ),
      ],
    );
  }
}
