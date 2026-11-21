// T-UI-117: прогон адаптивности служебных экранов — SCR-41 «Профиль» (сотрудник, клиент), SCR-42 «Настройки»
// (сотрудник, клиент), SCR-43 «Синхронизация», SCR-44 «Уведомления», SCR-45 «Пользователи», SCR-46 «Настройки
// администратора» (админ, руководитель), SCR-47 «Журнал», SCR-48 «Отчёты», SCR-54 «Планшеты магазина» — по окнам
// 360…2560 (портрет и ландшафт, окна масштаба страницы веб-демо) при масштабе текста 1 и 1,3: без переполнения и
// недоступных элементов (03 §8.8; указание владельца 2026-11-18, 15 §5.8 (3)). Синтетические данные.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_screen.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_screen.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_screen.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_screen.dart';
import 'package:optomstroy/features/notifications/presentation/screens/notifications_screen.dart';
import 'package:optomstroy/features/profile/presentation/screens/profile_screen.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';
import 'package:optomstroy/features/reports/presentation/screens/reports_screen.dart';
import 'package:optomstroy/features/reports/reports_providers.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/sync_status/presentation/notifiers/sync_status_controller.dart';
import 'package:optomstroy/features/sync_status/presentation/screens/sync_status_screen.dart';

import '../features/admin/support/fake_admin_repository.dart';
import '../features/admin/support/fake_admin_settings.dart';
import '../features/admin/support/fake_admin_tablets.dart';
import '../features/customer_mode/support/customer_profile_fakes.dart';
import '../features/notifications/notifications_test_support.dart';
import '../features/profile/presentation/profile_screen_test.dart' show FakeProfileRepository, TestSession;
import '../features/reports/support/fake_reports_repository.dart';
import '../features/settings/support/settings_fakes.dart' as st;
import '../features/sync_status/sync_status_screen_test.dart' show FakeSyncStatusPort;
import '../support/responsive_audit.dart';

Widget _app(Size size, List<Override> overrides, Widget home) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
      child: child!,
    ),
    home: home,
  ),
);

final class _Session extends SessionController {
  @override
  SessionState build() => SessionState.initial;
}

final class _Net implements NetworkSignalSource {
  const _Net();

  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

final DateTime _now = DateTime.utc(2026, 10, 22, 9);

Widget _staffProfile(Size size) => _app(size, <Override>[
  profileRepositoryProvider.overrideWithValue(FakeProfileRepository()),
  clockProvider.overrideWithValue(FixedClock(_now)),
  onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
  sessionControllerProvider.overrideWith(TestSession.new),
], const ProfileScreen());

Widget _customerProfile(Size size) => _app(size, <Override>[
  profileRepositoryProvider.overrideWithValue(FakeCustomerProfileRepository(customerMe(link: confirmedLink))),
  clockProvider.overrideWithValue(FixedClock(_now)),
  onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
  sessionControllerProvider.overrideWith(_Session.new),
], const ProfileScreen());

Widget _settings(Size size, SettingsViewer viewer) => _app(
  size,
  st.settingsOverrides(
    sessions: st.FakeSessionsRepository(<DeviceSession>[
      st.session('cur', current: true, name: 'Касса-1'),
      st.session('tab', name: 'Планшет склада', platform: DevicePlatform.android),
    ]),
    protection: st.FakeProtectionRepository(
      viewer.kind == UserKind.customer ? st.customerProtection : st.staffProtection,
    ),
    viewer: viewer,
    extra: <Override>[connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(const _Net()))],
  ),
  const SettingsScreen(),
);

Widget _sync(Size size) {
  final DateTime utcNow = DateTime.utc(2026, 10, 19, 9, 42);
  return _app(size, <Override>[
    syncStatusPortProvider.overrideWithValue(FakeSyncStatusPort()),
    syncViewerRoleProvider.overrideWithValue(RoleCode.seniorSeller),
    onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
    catalogFreshnessProvider.overrideWithValue(
      DataFreshness(online: OnlineStatus.online, now: utcNow, asOf: utcNow.subtract(const Duration(minutes: 30))),
    ),
    localSyncStatesProvider.overrideWith(
      (Ref ref) => Stream<List<LocalEntitySync>>.value(<LocalEntitySync>[
        for (final String e in const <String>['units', 'categories', 'warehouses', 'products', 'prices', 'stock'])
          LocalEntitySync(entity: e, asOf: utcNow.subtract(const Duration(minutes: 30))),
      ]),
    ),
    syncNowProvider.overrideWith((Ref ref) => Stream<DateTime>.value(utcNow)),
    clockProvider.overrideWithValue(FixedClock(utcNow)),
    syncStatusPollIntervalsProvider.overrideWithValue(null),
  ], Material(color: DsColors.lightB.background, child: const SyncStatusScreen()));
}

List<Override> _adminOverrides(AdminViewer me) => <Override>[
  ...adminTestOverrides(
    FakeAdminUsersRepository(
      me: me,
      users: <AdminUser>[staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова')],
    ),
  ),
  adminSettingsRepositoryProvider.overrideWithValue(FakeAdminSettingsRepository()),
  auditLogRepositoryProvider.overrideWithValue(FakeAuditLogRepository()),
];

FakeAdminUsersRepository _users(AdminViewer me) => FakeAdminUsersRepository(
  me: me,
  users: <AdminUser>[
    staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова', phone: '+996700000010'),
    staff(cashierId, name: 'Иван Петров', phone: '+996700000001'),
    staff(otherAdminId, role: RoleCode.admin, name: 'Бакыт Асанов', phone: '+996700000002'),
    staff(ownerId, role: RoleCode.owner, name: 'Нурлан Руководитель', phone: '+996700000003'),
    staff(pendingId, role: RoleCode.seller, name: 'Айгуль Продавец', status: 'blocked', phone: '+996700000004'),
  ],
  invitations: <Invitation>[
    Invitation(
      id: 'inv-1',
      phoneMasked: '+996 7** *** *07',
      roles: const <String>['seller'],
      status: 'pending',
      createdByName: 'Г. А.',
      createdAt: t0,
      expiresAt: t0.add(const Duration(days: 30)),
    ),
  ],
);

List<StoreTablet> _tablets() => <StoreTablet>[
  tablet(
    tabletAId,
    lastSeenAt: t0.subtract(const Duration(minutes: 3)),
    lockTaskEnabled: true,
    expiresAt: t0.add(const Duration(days: 200)),
  ),
  tablet(
    tabletBId,
    name: 'Планшет у кассы',
    warehouseId: warehouseSecondId,
    lastSeenAt: t0.subtract(const Duration(hours: 2)),
    appVersion: '1.3.9+80',
    expiresAt: t0.add(const Duration(days: 20)),
  ),
  tablet(
    '0192f3a1-6c3e-7a1b-9f00-0000000005c1',
    name: 'Планшет склада',
    status: StoreTabletStatus.revoked,
    lastSeenAt: t0.subtract(const Duration(days: 10)),
    lockTaskEnabled: true,
  ),
];

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, RespBuild> scenes = <String, RespBuild>{
    'scr41_profile_staff': (Size s, double _) => _staffProfile(s),
    'scr41_profile_customer': (Size s, double _) => _customerProfile(s),
    'scr42_settings_staff': (Size s, double _) =>
        _settings(s, const SettingsViewer(kind: UserKind.staff, primaryRole: RoleCode.cashier)),
    'scr42_settings_customer': (Size s, double _) => _settings(s, const SettingsViewer(kind: UserKind.customer)),
    'scr43_sync': (Size s, double _) => _sync(s),
    'scr44_notifications': (Size s, double _) => _app(s, NotifStand().overrides, const NotificationsScreen()),
    'scr45_users': (Size s, double _) => _app(s, adminTestOverrides(_users(adminViewer)), const AdminUsersScreen()),
    'scr46_admin_settings': (Size s, double _) => _app(s, _adminOverrides(adminViewer), const AdminSettingsScreen()),
    'scr46_owner_settings': (Size s, double _) => _app(s, _adminOverrides(ownerViewer), const AdminSettingsScreen()),
    'scr47_audit': (Size s, double _) => _app(s, _adminOverrides(ownerViewer), const AuditScreen()),
    'scr48_reports': (Size s, double _) => _app(s, <Override>[
      reportsRepositoryProvider.overrideWithValue(FakeReportsRepository()),
      clockProvider.overrideWithValue(FixedClock(r0)),
    ], const ReportsScreen(report: 'sales')),
    'scr54_tablets': (Size s, double _) => _app(
      s,
      tabletsOverrides(
        FakeAdminTabletsRepository(tablets: _tablets()),
        me: adminViewer,
        device: FakeKioskDevice(),
        recommendedVersion: '1.4.2',
      ),
      const AdminTabletsScreen(),
    ),
  };

  for (final MapEntry<String, RespBuild> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value);
      audit.expectNoBlocking();
    });
  }
}
