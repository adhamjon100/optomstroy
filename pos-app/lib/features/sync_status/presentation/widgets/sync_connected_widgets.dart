// Подключённые к core/sync виджеты для оболочек приложения (app/router/shells) и SCR-43:
// `ConnectedOfflineBanner` (03 §9.41), `ConnectedSyncIndicator` (03 §9.40), `CatalogInitialLoadBanner`
// (NFR-PERF-006: «Загружаем каталог… N %»). Фичи, которым импорт sync_status недоступен по DAG (catalog, home),
// собирают то же из компонентов design_system и провайдеров core/sync (`catalogFreshnessProvider`,
// `syncIndicatorProvider`, `catalogLoadStateProvider`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_side_sheet.dart';

/// Вариант баннера по доступности backend (без `backOnline` — его добавляет [ConnectedOfflineBanner]).
OfflineBannerVariant? offlineBannerVariantOf(OnlineStatus status) => switch (status) {
  OnlineStatus.offline => OfflineBannerVariant.offline,
  OnlineStatus.serverDown => OfflineBannerVariant.serverDown,
  OnlineStatus.online || OnlineStatus.unknown => null,
};

/// Вариант `SyncIndicator` по состоянию core/sync.
SyncIndicatorVariant syncIndicatorVariantOf(SyncIndicatorStatus s) => switch (s) {
  SyncIndicatorStatus.ok => SyncIndicatorVariant.ok,
  SyncIndicatorStatus.syncing => SyncIndicatorVariant.syncing,
  SyncIndicatorStatus.stale => SyncIndicatorVariant.stale,
  SyncIndicatorStatus.error => SyncIndicatorVariant.error,
  SyncIndicatorStatus.offline => SyncIndicatorVariant.offline,
  SyncIndicatorStatus.never => SyncIndicatorVariant.never,
};

/// Глобальный `OfflineBanner`: офлайн («Показаны данные от HH:MM»), сервер недоступен, переподключение,
/// «Сеть восстановлена…» на 3 с после возврата связи.
class ConnectedOfflineBanner extends ConsumerStatefulWidget {
  const ConnectedOfflineBanner({super.key, this.onRetry});

  /// «Повторить» для `serverDown` (по умолчанию — проверка `GET /health`).
  final VoidCallback? onRetry;

  /// Сколько показывать `backOnline`.
  static const Duration backOnlineFor = Duration(seconds: 3);

  @override
  ConsumerState<ConnectedOfflineBanner> createState() => _ConnectedOfflineBannerState();
}

class _ConnectedOfflineBannerState extends ConsumerState<ConnectedOfflineBanner> {
  Timer? _hide;
  bool _backOnline = false;
  bool _reconnecting = false;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _onStatus(OnlineStatus? previous, OnlineStatus? next) {
    if (next == null) return;
    final wasDown = previous == OnlineStatus.offline || previous == OnlineStatus.serverDown;
    if (previous == OnlineStatus.offline && next == OnlineStatus.unknown) {
      setState(() => _reconnecting = true);
      return;
    }
    if ((wasDown || _reconnecting) && next == OnlineStatus.online) {
      _hide?.cancel();
      setState(() {
        _reconnecting = false;
        _backOnline = true;
      });
      _hide = Timer(ConnectedOfflineBanner.backOnlineFor, () {
        if (mounted) setState(() => _backOnline = false);
      });
      return;
    }
    if (_reconnecting && next != OnlineStatus.unknown) setState(() => _reconnecting = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<OnlineStatus?>(onlineStatusProvider.select((s) => s.value), _onStatus);
    final freshness = ref.watch(catalogFreshnessProvider);
    final l10n = AppLocalizations.of(context);
    var variant = offlineBannerVariantOf(freshness.online);
    if (variant == null && _reconnecting) variant = OfflineBannerVariant.reconnecting;
    if (variant == null && _backOnline) variant = OfflineBannerVariant.backOnline;
    return OfflineBanner(
      variant: variant,
      dataAsOf: freshness.asOf,
      now: ref.watch(syncNowProvider).value ?? ref.read(clockProvider).nowUtc(),
      actionLabel: variant == OfflineBannerVariant.serverDown ? l10n.ds_button_retry : null,
      onAction: variant == OfflineBannerVariant.serverDown
          ? (widget.onRetry ?? () => ref.invalidate(backendHealthReportProvider))
          : null,
    );
  }
}

/// `SyncIndicator` в шапке: тап → SCR-43 поверх текущего экрана (02 SCR-43.6, AC-UI-43-015): на expanded/large
/// у `seller`/`cashier`/`senior_seller` — side sheet 480 без смены URL ([SyncStatusSideSheet]), иначе — экран
/// `/sync` через `push` («Назад» возвращает туда, откуда открыт; `go` заменил бы стек).
///
/// [adaptive] (шапка medium+, ADR-112; 02 SCR-10.3 A6, 03 §9.40): пока всё в порядке (`ok`, `never`,
/// `syncing`) — только иконка с тултипом «обновлено HH:MM» (полная подпись — в `Semantics`); при `stale`,
/// `error` и `offline` — иконка с текстом («данные от …», «ошибка синхронизации», «нет сети»).
class ConnectedSyncIndicator extends ConsumerWidget {
  const ConnectedSyncIndicator({super.key, this.compact, this.onTap, this.adaptive = false});

  /// Только иконка; `null` — по классу окна: compact — иконка, иначе иконка + время (02 SCR-10.3 A6).
  /// При [adaptive] не учитывается.
  final bool? compact;

  /// По умолчанию — [SyncStatusSideSheet.open].
  final VoidCallback? onTap;

  /// Вид по состоянию (шапка medium+): в норме — только иконка, при проблеме — иконка с текстом.
  final bool adaptive;

  /// Состояние в норме — в адаптивном режиме показывается только иконка.
  static bool quietVariant(SyncIndicatorVariant v) =>
      v == SyncIndicatorVariant.ok || v == SyncIndicatorVariant.never || v == SyncIndicatorVariant.syncing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(syncIndicatorProvider);
    final SyncIndicatorVariant variant = syncIndicatorVariantOf(info.status);
    // «Сейчас» для метки «обновлено HH:MM» (без даты — только в тот же день Бишкека).
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool iconOnly = adaptive
        ? context.windowClass == WindowClass.compact || quietVariant(variant)
        : compact ?? context.windowClass == WindowClass.compact;
    return SyncIndicator(
      variant: variant,
      time: info.time,
      now: now,
      compact: iconOnly,
      // Только иконка — подпись состояния во всплывающей подсказке (`ds_updated_at` «обновлено HH:MM» и т. п.).
      tooltip: adaptive && iconOnly ? SyncIndicator.labelOf(context, variant, time: info.time, now: now) : null,
      onTap: onTap ?? () => unawaited(SyncStatusSideSheet.open(context, role: ref.read(syncViewerRoleProvider))),
    );
  }
}

/// Индикатор первичной загрузки каталога (NFR-PERF-006): полоса прогресса + «Загружаем каталог… N %».
class CatalogInitialLoadBanner extends ConsumerWidget {
  const CatalogInitialLoadBanner({super.key});

  static const Key bannerKey = Key('catalog-initial-load');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(catalogLoadStateProvider).value ?? const CatalogLoadState();
    if (load.phase != CatalogLoadPhase.initialLoading) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final label = l10n.catalog_initial_loading('${load.percent}');
    return Padding(
      key: bannerKey,
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      // `AppProgress.stepped` — «загрузка каталога по сущностям» (03 §9.63): сегмент на сущность 07 §11.4.
      child: AppProgress.stepped(
        steps: load.totalEntities == 0 ? 1 : load.totalEntities,
        completedSteps: load.completedEntities.length,
        label: label,
        semanticLabel: label,
      ),
    );
  }
}
