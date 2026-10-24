// Golden RM-E-009 (alchemist; D-18): компоненты `OfflineBanner` (03 §9.41), `SyncIndicator` (03 §9.40, включая
// compact и inline — метку возраста данных) и экран SCR-43 (`senior_seller`, `admin`, офлайн; side sheet 480
// `senior_seller` на expanded) на брейкпоинтах
// compact / medium / expanded, палитра B, reduce-motion. Эталоны — Windows (`goldens/windows/`) и CI (`goldens/ci/`).
//
// Обновить эталоны: flutter test test/features/sync_status/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/sync_indicator.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/sync_status/presentation/notifiers/sync_status_controller.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_side_sheet.dart';

import '../sync_status_screen_test.dart' show FakeSyncStatusPort;

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

// Местное время (эталоны не зависят от часового пояса машины): «сегодня 09:41».
final DateTime _at = DateTime(2026, 10, 19, 9, 41);
final DateTime _now = DateTime(2026, 10, 19, 10);

Widget _frame(Size size, Widget child) => MaterialApp(
  theme: AppTheme.light(),
  locale: const Locale('ru'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  debugShowCheckedModeBanner: false,
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
    child: app!,
  ),
  home: Material(color: DsColors.lightB.background, child: child),
);

Widget _components(Size size) => _frame(
  size,
  SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OfflineBanner(variant: OfflineBannerVariant.offline, dataAsOf: _at, now: _now),
        const SizedBox(height: 8),
        const OfflineBanner(variant: OfflineBannerVariant.reconnecting),
        const SizedBox(height: 8),
        const OfflineBanner(variant: OfflineBannerVariant.backOnline),
        const SizedBox(height: 8),
        OfflineBanner(variant: OfflineBannerVariant.serverDown, actionLabel: 'Повторить', onAction: () {}),
        const SizedBox(height: 8),
        const OfflineBanner(variant: OfflineBannerVariant.onecDown),
        const SizedBox(height: 8),
        const OfflineBanner(variant: null),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 16,
            runSpacing: 12,
            children: <Widget>[
              SyncIndicator(variant: SyncIndicatorVariant.ok, time: _at, now: _now),
              SyncIndicator(variant: SyncIndicatorVariant.syncing, time: _at, now: _now),
              SyncIndicator(variant: SyncIndicatorVariant.stale, time: _at, now: _now),
              const SyncIndicator(variant: SyncIndicatorVariant.error),
              const SyncIndicator(variant: SyncIndicatorVariant.offline),
              const SyncIndicator(variant: SyncIndicatorVariant.never),
              const SyncIndicator(variant: SyncIndicatorVariant.ok, compact: true),
              const SyncIndicator(variant: SyncIndicatorVariant.stale, compact: true),
              const SyncIndicator(variant: SyncIndicatorVariant.error, compact: true),
              SyncIndicator.inline(time: _at, now: _now),
              SyncIndicator.inline(time: _at, stale: true, now: _now),
            ],
          ),
        ),
      ],
    ),
  ),
);

Widget _screen(Size size, RoleCode role, {bool offline = false, bool sheet = false}) {
  final status = offline ? OnlineStatus.offline : OnlineStatus.online;
  final utcNow = DateTime.utc(2026, 10, 19, 9, 42);
  return SizedBox(
    width: size.width,
    height: size.height,
    child: ProviderScope(
      overrides: <Override>[
        syncStatusPortProvider.overrideWithValue(FakeSyncStatusPort()),
        syncViewerRoleProvider.overrideWithValue(role),
        onlineStatusProvider.overrideWith((ref) => Stream<OnlineStatus>.value(status)),
        catalogFreshnessProvider.overrideWithValue(
          DataFreshness(online: status, now: utcNow, asOf: utcNow.subtract(const Duration(minutes: 30))),
        ),
        localSyncStatesProvider.overrideWith(
          (ref) => Stream<List<LocalEntitySync>>.value([
            for (final e in const ['units', 'categories', 'warehouses', 'products', 'variants', 'prices', 'stock'])
              LocalEntitySync(entity: e, asOf: utcNow.subtract(const Duration(minutes: 30))),
          ]),
        ),
        syncNowProvider.overrideWith((ref) => Stream<DateTime>.value(utcNow)),
        clockProvider.overrideWithValue(FixedClock(utcNow)),
        syncStatusPollIntervalsProvider.overrideWithValue(null),
      ],
      child: _frame(
        size,
        sheet
            // Side sheet 480 поверх экрана (02 SCR-43.2 «Expanded», FIX-EF-08): затемнение + краткий SCR-43.
            ? Stack(
                children: <Widget>[
                  Positioned.fill(child: ColoredBox(color: DsColors.lightB.overlay)),
                  SyncStatusSideSheet.panel(onMore: () {}),
                ],
              )
            : const SyncStatusScreen(),
      ),
    ),
  );
}

void main() {
  unawaited(
    goldenTest(
      'SCR-43 side sheet senior_seller · expanded',
      fileName: 'scr43_sheet_senior_seller_expanded',
      constraints: BoxConstraints.tight(_windows['expanded']!),
      builder: () => _screen(_windows['expanded']!, RoleCode.seniorSeller, sheet: true),
    ),
  );
  for (final MapEntry<String, Size> w in _windows.entries) {
    unawaited(
      goldenTest(
        'OfflineBanner + SyncIndicator · ${w.key}',
        fileName: 'sync_components_${w.key}',
        constraints: BoxConstraints.tight(Size(w.value.width, 520)),
        builder: () => _components(Size(w.value.width, 520)),
      ),
    );
    for (final scene in <(String, RoleCode, bool)>[
      ('senior_seller', RoleCode.seniorSeller, false),
      ('admin', RoleCode.admin, false),
      ('offline', RoleCode.seniorSeller, true),
    ]) {
      unawaited(
        goldenTest(
          'SCR-43 ${scene.$1} · ${w.key}',
          fileName: 'scr43_${scene.$1}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          builder: () => _screen(w.value, scene.$2, offline: scene.$3),
        ),
      );
    }
  }
}
