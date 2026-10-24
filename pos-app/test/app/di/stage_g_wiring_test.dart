// Этап G (основа): композиционный корень `appOverrides` подключает реализации data всех портов этапа G
// (клиенты: справочник/долги/избранные; касса; журнал операций; возвраты; отчёты; профиль; SCR-46/SCR-47), память
// финансов клиента — только процесс (CASH-015), флаги guard-ов — из `GET /settings/public` (RM-G-005, RM-G-013).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/guards/role_guard.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show QrProviderMode;
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/data/settings/dio_admin_settings_repository.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/data/repositories/dio_cashier_repository.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/data/repositories/dio_customer_g_repositories.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/profile/data/repositories/dio_profile_repository.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';
import 'package:optomstroy/features/reports/data/repositories/dio_reports_repository.dart';
import 'package:optomstroy/features/reports/reports_providers.dart';
import 'package:optomstroy/features/returns/data/repositories/dio_returns_repository.dart';
import 'package:optomstroy/features/returns/returns_providers.dart';
import 'package:optomstroy/features/transactions/data/repositories/dio_transactions_repository.dart';
import 'package:optomstroy/features/transactions/transactions_providers.dart';

final class _Net implements NetworkSignalSource {
  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

ProviderContainer _root({PublicFeatureFlags? flags}) {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      ...appOverrides,
      connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net())),
      clientMetaProvider.overrideWithValue(
        const ClientMeta(
          appVersion: '0.1.0+1',
          platform: ClientPlatform.windows,
          deviceId: '3f2b8c1e-5d4a-4b6c-9e7f-0a1b2c3d4e5f',
        ),
      ),
      if (flags != null) publicFeatureFlagsProvider.overrideWithValue(flags),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

PublicFeatureFlags _flags({required bool fromServer, bool returns = false, bool debt = false}) => PublicFeatureFlags(
  customerSelfService: true,
  returnsFromPos: returns,
  qrProvider: QrProviderMode.onec,
  qrWebhook: false,
  debtPaymentsFromPos: debt,
  fromServer: fromServer,
);

void main() {
  test('порты этапа G подключены к реализациям data', () {
    final ProviderContainer c = _root();
    expect(c.read(customerDirectoryRepositoryProvider), isA<DioCustomerDirectoryRepository>());
    expect(c.read(receivablesRepositoryProvider), isA<DioReceivablesRepository>());
    expect(c.read(favoriteCustomersRepositoryProvider), isA<DioFavoriteCustomersRepository>());
    expect(c.read(cashierRepositoryProvider), isA<DioCashierRepository>());
    expect(c.read(transactionsRepositoryProvider), isA<DioTransactionsRepository>());
    expect(c.read(returnsRepositoryProvider), isA<DioReturnsRepository>());
    expect(c.read(reportsRepositoryProvider), isA<DioReportsRepository>());
    expect(c.read(profileRepositoryProvider), isA<DioProfileRepository>());
    expect(c.read(adminSettingsRepositoryProvider), isA<DioAdminSettingsRepository>());
    expect(c.read(auditLogRepositoryProvider), isA<DioAuditLogRepository>());
  });

  test('финансы клиента — память процесса (CASH-015); флаги до ответа сервера: возвраты не закрыты, долг — закрыт', () {
    final ProviderContainer c = _root(flags: _flags(fromServer: false));
    expect(c.read(customerFinanceMemoryProvider), isA<InMemoryCustomerFinanceMemory>());
    expect(c.read(debtPaymentsFromPosProvider), isFalse);
    expect(c.read(returnsEnabledProvider), isFalse, reason: 'кнопки скрыты до ответа сервера');
    expect(c.read(routeFeaturesProvider), RouteFeatures.defaults);
  });

  test(
    'флаги сервера доходят до guard-ов: returns_enabled=false закрывает /returns, debtPaymentsFromPos=true — нет',
    () {
      expect(
        _root(flags: _flags(fromServer: true)).read(routeFeaturesProvider),
        const RouteFeatures(returnsEnabled: false),
      );
      final ProviderContainer on = _root(flags: _flags(fromServer: true, returns: true, debt: true));
      expect(on.read(routeFeaturesProvider), const RouteFeatures(returnsEnabled: true, debtPaymentsFromPos: true));
      expect((on.read(returnsEnabledProvider), on.read(debtPaymentsFromPosProvider)), (true, true));
    },
  );

  test('без композиционного корня порты этапа G не подключены (явная ошибка, а не тихая заглушка)', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(() => c.read(cashierRepositoryProvider), throwsA(anything));
    expect(() => c.read(returnsRepositoryProvider), throwsA(anything));
    expect(c.read(routeFeaturesProvider), RouteFeatures.defaults);
  });
}
