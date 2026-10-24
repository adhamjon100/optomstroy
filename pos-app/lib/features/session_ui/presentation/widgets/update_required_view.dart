// SCR-90 зона C3 «Требуется обновление» (02 §3.3, G-12; 08 §2.11; D-46): `426 APP_UPDATE_REQUIRED`
// или `X-Min-App-Version` выше текущей — блокирующий слой, навигация под ним заморожена, «Назад» не уводит.
// Кнопка «Обновить» — только при https-ссылке `storeUrl` и переданном открывателе (иначе — инструкция).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

class UpdateRequiredView extends StatelessWidget {
  const UpdateRequiredView({super.key, this.minVersion, this.storeUrl, this.openStoreUrl});

  static const Key viewKey = Key('scr-90-update-required-layer');
  static const Key updateKey = Key('scr-90-update-required-action');

  final String? minVersion;
  final String? storeUrl;
  final Future<void> Function(Uri url)? openStoreUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final url = storeUrl == null ? null : Uri.tryParse(storeUrl!);
    final opener = openStoreUrl;
    return Material(
      key: viewKey,
      color: c.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: EdgeInsets.all(context.space.s5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.system_update_rounded, size: 72, color: c.primary),
                  SizedBox(height: context.space.s4),
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.ds_update_required,
                      textAlign: TextAlign.center,
                      style: context.text.h3.copyWith(color: c.textPrimary),
                    ),
                  ),
                  if (minVersion != null) ...<Widget>[
                    SizedBox(height: context.space.s2),
                    Text(
                      l10n.global_update_body(minVersion!),
                      textAlign: TextAlign.center,
                      style: context.text.body.copyWith(color: c.textSecondary),
                    ),
                  ],
                  if (url != null && url.isScheme('https') && opener != null) ...<Widget>[
                    SizedBox(height: context.space.s5),
                    AppButton(
                      key: updateKey,
                      label: l10n.global_update_action,
                      icon: Icons.download_rounded,
                      expand: true,
                      onPressed: () => opener(url),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
