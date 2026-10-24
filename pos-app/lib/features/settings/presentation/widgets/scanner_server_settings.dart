// Серверные настройки сканера в секции «Сканер штрихкодов» SCR-42 (UI-42-011 режим HID/камера, UI-42-019
// «Сразу добавлять в корзину»; 08 §3.14 `Settings.scanner.mode`, `scanAddsToCart`; ядро §19.4). Окончание скана
// и тест сканера — секция фичи scan (`settingsScannerSectionProvider`). Камера на Windows скрыта (02 SCR-42.12).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/notifiers/settings_controllers.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// Ключи для тестов.
abstract final class ScannerServerSettingsKeys {
  static const Key modeHid = ValueKey<String>('settings-scanner-mode-hid');
  static const Key modeCamera = ValueKey<String>('settings-scanner-mode-camera');
  static const Key addsToCart = ValueKey<String>('settings-scanner-adds-to-cart');
}

class ScannerServerSettings extends ConsumerWidget {
  const ScannerServerSettings({super.key, this.platform});

  /// Платформа (тесты); по умолчанию — платформа сборки.
  final TargetPlatform? platform;

  /// Умолчание «Сразу добавлять в корзину» (ядро §19.4): `cashier` — вкл., прочие — выкл. (Q-261).
  static bool defaultAddsToCart(RoleCode? role) => role == RoleCode.cashier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SecurityViewState s = ref.watch(securityControllerProvider);
    final LoginProtectionState? data = s.data;
    if (data == null) return const SizedBox.shrink();
    final SettingsViewer viewer = ref.watch(settingsViewerProvider);
    final bool camera = (platform ?? defaultTargetPlatform) != TargetPlatform.windows;
    final String mode = data.scannerMode ?? 'hid';
    final SecurityController controller = ref.read(securityControllerProvider.notifier);

    Future<void> save({String? mode, bool? addsToCart}) async {
      final Failure? failure = await controller.setScannerSettings(mode: mode, addsToCart: addsToCart);
      if (failure != null && context.mounted) {
        AppSnackbar.show(context, message: SettingsTexts.failure(l10n, failure), variant: AppSnackbarVariant.error);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppRadio<String>(
          key: ScannerServerSettingsKeys.modeHid,
          value: 'hid',
          groupValue: mode,
          label: l10n.settings_scanner_mode_hid,
          onChanged: (String v) => unawaited(save(mode: v)),
        ),
        if (camera)
          AppRadio<String>(
            key: ScannerServerSettingsKeys.modeCamera,
            value: 'camera',
            groupValue: mode,
            label: l10n.settings_scanner_mode_camera,
            onChanged: (String v) => unawaited(save(mode: v)),
          ),
        SizedBox(height: context.space.s2),
        AppSwitch(
          key: ScannerServerSettingsKeys.addsToCart,
          value: data.scanAddsToCart ?? defaultAddsToCart(viewer.primaryRole),
          label: l10n.settings_scanner_add_to_cart,
          onChanged: (bool v) => unawaited(save(addsToCart: v)),
        ),
        SizedBox(height: context.space.s4),
      ],
    );
  }
}
