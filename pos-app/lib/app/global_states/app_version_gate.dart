import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Открытие ссылки обновления (`storeUrl` тела 426). Платформенная реализация (url_launcher / MDM) — RM-H;
/// до неё кнопка «Обновить» не показывается и SCR-90 даёт инструкцию (Q-132: администратор ставит сборку вручную).
typedef StoreUrlOpener = Future<void> Function(Uri url);

/// Состояние версии для SCR-90. Без `clientMetaProvider` (bootstrap не смог прочитать метаданные клиента, см.
/// app/bootstrap.dart, или виджет-тест без bootstrap) запросы API не уходят — ограничений версии нет.
final appVersionGateStateProvider = Provider<AppVersionState>((ref) {
  try {
    ref.watch(clientMetaProvider);
  } on Object {
    // UnimplementedError (Riverpod 3 оборачивает в ProviderException): метаданных клиента нет.
    return AppVersionState.initial;
  }
  return ref.watch(appVersionStateProvider);
});

/// SCR-90 «Требуется обновление» и мягкий баннер «Доступна новая версия» (RM-C-015 п. 3; 06 §6.16, D-46).
///
/// Глобальное состояние поверх навигации: при `updateRequired` (ответ `426 APP_UPDATE_REQUIRED` или минимальная
/// версия из `X-Min-App-Version` выше текущей) приложение заменяется блокирующим экраном без выхода назад; при
/// `updateRecommended` над приложением — баннер с кнопкой «Позже», работа не блокируется.
class AppVersionGate extends ConsumerStatefulWidget {
  /// Создаёт гейт над [child].
  const AppVersionGate({super.key, required this.child, this.openStoreUrl});

  /// Содержимое приложения (навигатор).
  final Widget child;

  /// Открытие `storeUrl`; `null` — кнопка «Обновить» скрыта.
  final StoreUrlOpener? openStoreUrl;

  @override
  ConsumerState<AppVersionGate> createState() => _AppVersionGateState();
}

class _AppVersionGateState extends ConsumerState<AppVersionGate> {
  /// Рекомендуемая версия, баннер которой закрыт кнопкой «Позже» (до новой рекомендуемой версии).
  String? _dismissedRecommended;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appVersionGateStateProvider);
    switch (state.status) {
      case AppVersionStatus.updateRequired:
        return UpdateRequiredScreen(state: state, openStoreUrl: widget.openStoreUrl);
      case AppVersionStatus.updateRecommended when state.recommended != _dismissedRecommended:
        return Column(
          children: <Widget>[
            UpdateAvailableBanner(onLater: () => setState(() => _dismissedRecommended = state.recommended)),
            Expanded(
              child: MediaQuery.removePadding(context: context, removeTop: true, child: widget.child),
            ),
          ],
        );
      case AppVersionStatus.updateRecommended:
      case AppVersionStatus.ok:
        return widget.child;
    }
  }
}

/// SCR-90 «Требуется обновление» — блокирующий экран (кнопки «Назад» нет, системный «Назад» не уводит в приложение).
class UpdateRequiredScreen extends StatelessWidget {
  /// Создаёт экран.
  const UpdateRequiredScreen({super.key, required this.state, this.openStoreUrl});

  /// Ключ экрана (тесты, integration_test).
  static const Key screenKey = Key('scr-90-update-required');

  /// Ключ кнопки «Обновить».
  static const Key updateButtonKey = Key('scr-90-update-action');

  /// Состояние версии.
  final AppVersionState state;

  /// Открытие `storeUrl`.
  final StoreUrlOpener? openStoreUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    final url = state.storeUrl == null ? null : Uri.tryParse(state.storeUrl!);
    final opener = openStoreUrl;
    return PopScope(
      canPop: false,
      child: Material(
        key: screenKey,
        color: colors.background,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: EdgeInsets.all(context.space.s5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.system_update_rounded, size: 72, color: colors.primary),
                    SizedBox(height: context.space.s4),
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.ds_update_required,
                        textAlign: TextAlign.center,
                        style: context.text.h3.copyWith(color: colors.textPrimary),
                      ),
                    ),
                    if (state.minimum != null) ...<Widget>[
                      SizedBox(height: context.space.s2),
                      Text(
                        l10n.global_update_body(state.minimum!),
                        textAlign: TextAlign.center,
                        style: context.text.body.copyWith(color: colors.textSecondary),
                      ),
                    ],
                    if (url != null && opener != null) ...<Widget>[
                      SizedBox(height: context.space.s5),
                      AppButton(
                        key: updateButtonKey,
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
      ),
    );
  }
}

/// Мягкий баннер «Доступна новая версия приложения» с кнопкой «Позже» (D-46: без блокировки работы).
class UpdateAvailableBanner extends StatelessWidget {
  /// Создаёт баннер.
  const UpdateAvailableBanner({super.key, required this.onLater});

  /// Ключ баннера (тесты).
  static const Key bannerKey = Key('scr-90-update-available');

  /// «Позже» — скрыть баннер до следующей рекомендуемой версии.
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.colors;
    return Material(
      key: bannerKey,
      color: colors.infoContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s1),
          child: Row(
            children: <Widget>[
              Icon(Icons.system_update_rounded, size: 20, color: colors.info),
              SizedBox(width: context.space.s2),
              Expanded(
                child: Text(l10n.global_update_soft, style: context.text.label.copyWith(color: colors.textPrimary)),
              ),
              AppButton(
                label: l10n.global_update_later,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: onLater,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
