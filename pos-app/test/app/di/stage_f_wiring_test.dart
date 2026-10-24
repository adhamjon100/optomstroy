// RM-F-011 (интеграция F): адаптеры корня app/di — «Повторить заказ» над корзиной (02 UI-24-011/020), «Скачать PDF»
// через «Сохранить как…» (02 SCR-24.4, AC-UI-24-017), предпочтения SCR-21 в drift `settings` (02 SCR-21.9) и порты
// `stageFOverrides` (роль/QR для SCR-24/25, бейдж уведомлений каталога, слоты баннеров).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/checkout_prefs_drift_store.dart';
import 'package:optomstroy/app/di/file_selector_document_saver.dart';
import 'package:optomstroy/app/di/order_repeat_cart_adapter.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/settings_dao.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_banner_port.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_submission_port.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_announcements.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart';

import '../../features/cart/support/cart_test_support.dart';
import '../../support/f_fakes.dart';

OrderLine _line(String variantId, int units) => OrderLine(
  lineNo: 1,
  variantId: variantId,
  quantity: LineQuantity(value: Qty.units(units), unitId: 'u-pc'),
);

void main() {
  group('CartSyncOrderRepeatPort (UI-24-011, UI-24-020)', () {
    late FakeCartRepository repo;
    late FakeCartSync sync;
    late CartSyncOrderRepeatPort port;

    setUp(() {
      repo = FakeCartRepository();
      sync = FakeCartSync(repo)..server = emptyCart(rowVersion: 7);
      port = CartSyncOrderRepeatPort(sync, repo);
    });

    test('строка → PUT mode=increment с ключом строки и текущим rowVersion; цена не передаётся', () async {
      repo.onPutItem = (String v, CartItemPut put, String? key) async => Success<Cart>(emptyCart(rowVersion: 8));
      final Result<bool> r = await port.addLine(_line('v-1', 3), idempotencyKey: 'k-1');
      expect(r.valueOrNull, isTrue);
      final List<Object?> args = repo.calls.single.args;
      expect(args[0], 'v-1');
      final CartItemPut put = args[1]! as CartItemPut;
      expect(put.mode, CartPutMode.increment);
      expect(put.rowVersion, 7);
      expect(put.quantity.value, Qty.units(3));
      expect(put.priceSnapshot, isNull);
      expect(args[2], 'k-1');
      expect(sync.server?.rowVersion, 8, reason: 'ответ — новая копия корзины');
    });

    test('VARIANT_UNAVAILABLE → Success(false) (строка пропущена); прочие ошибки — FailureResult', () async {
      repo.onPutItem = (_, _, _) async => const FailureResult<Cart>(ConflictFailure(ConflictKind.variantUnavailable));
      expect((await port.addLine(_line('v-2', 1), idempotencyKey: 'k-2')).valueOrNull, isFalse);
      repo.onPutItem = (_, _, _) async => const FailureResult<Cart>(NetworkFailure(NetworkFailureKind.offline));
      expect(await port.addLine(_line('v-3', 1), idempotencyKey: 'k-3'), isA<FailureResult<bool>>());
    });

    test('число позиций активной корзины и «Отложить текущую» (POST /cart/park с ключом)', () async {
      repo.onFetch = () async => Success<Cart>(canonCart());
      expect((await port.activeCartItemsCount()).valueOrNull, 5);
      repo.onPark = (int rv, String? name, String key) async => Success<CartParkResult>(
        CartParkResult(
          parked: canonCart(),
          active: emptyCart(id: 'cart-2'),
        ),
      );
      expect(await port.parkActiveCart(idempotencyKey: 'park-1'), isA<Success<void>>());
      expect(repo.calls.last.method, 'park');
      expect(repo.calls.last.args[2], 'park-1');
      expect(sync.server?.id, 'cart-2');
    });
  });

  test('F-flutter-ui-6: restoredCartLocation — активная восстановленная → /cart, иначе (отложена) → /cart/parked', () async {
    final FakeCartRepository repo = FakeCartRepository()
      ..onFetch = () async => const Success<Cart>(
        Cart(id: 'c', status: CartStatus.active, rowVersion: 1, items: <CartLine>[], restoredFromOrderId: 'o1'),
      );
    expect(await restoredCartLocation(repo, 'o1'), '/cart');
    expect(await restoredCartLocation(repo, 'o2'), '/cart/parked');
  });

  group('FileSelectorOrderDocumentSaver (AC-UI-24-017)', () {
    test('файл пишется только по пути из диалога; отмена — false', () async {
      final Directory dir = await Directory.systemTemp.createTemp('saver_test');
      addTearDown(() => dir.delete(recursive: true));
      final String target = '${dir.path}${Platform.pathSeparator}receipt.pdf';
      String? suggested;
      final FileSelectorOrderDocumentSaver saver = FileSelectorOrderDocumentSaver(
        pick: (String name) async {
          suggested = name;
          return target;
        },
      );
      const OrderDocumentFile file = OrderDocumentFile(bytes: <int>[0x25, 0x50, 0x44, 0x46], fileName: 'receipt-1.pdf');
      expect(await saver.saveAs(file), isTrue);
      expect(suggested, 'receipt-1.pdf');
      expect(await File(target).readAsBytes(), <int>[0x25, 0x50, 0x44, 0x46]);
      expect(await FileSelectorOrderDocumentSaver(pick: (_) async => null).saveAs(file), isFalse);
    });

    test('«Сохранить как…» — только Windows/macOS/Linux (Android/iOS — кнопка скрыта)', () {
      expect(fileSelectorSaveSupported(TargetPlatform.windows), isTrue);
      expect(fileSelectorSaveSupported(TargetPlatform.android), isFalse);
      expect(fileSelectorSaveSupported(TargetPlatform.iOS), isFalse);
    });
  });

  group('DriftCheckoutPrefsStore (02 SCR-21.9)', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('запись в settings scope=device и чтение новым экземпляром; credit не сохраняется', () async {
      final DriftCheckoutPrefsStore a = DriftCheckoutPrefsStore(SettingsDao(db), nowMs: () => 1000);
      await a.loaded;
      expect(a.read().printInvoice, isTrue, reason: 'умолчание');
      a.write(
        const CheckoutPrefs(
          deliveryMethod: DeliveryMethod.pickup,
          paymentMethod: PaymentMethod.qrBakai,
          printInvoice: false,
          printReceipt: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final DriftCheckoutPrefsStore b = DriftCheckoutPrefsStore(SettingsDao(db), nowMs: () => 2000);
      await b.loaded;
      expect(b.read().deliveryMethod, DeliveryMethod.pickup);
      expect(b.read().paymentMethod, PaymentMethod.qrBakai);
      expect(b.read().printInvoice, isFalse);
      expect(b.read().printReceipt, isTrue);
      final List<SettingRow> rows = await db.select(db.localSettings).get();
      expect(rows.every((SettingRow r) => r.scope == SettingScope.device.value), isTrue);

      b.write(const CheckoutPrefs(paymentMethod: PaymentMethod.credit));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final DriftCheckoutPrefsStore c = DriftCheckoutPrefsStore(SettingsDao(db), nowMs: () => 3000);
      await c.loaded;
      expect(c.read().paymentMethod, isNull, reason: 'долг никогда не предвыбирается');
    });
  });

  group('stageFOverrides', () {
    ProviderContainer container(RoleCode? role, QrProviderMode qr) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          ...stageFOverrides,
          catalogViewerRoleProvider.overrideWithValue(role),
          publicFeatureFlagsProvider.overrideWithValue(
            PublicFeatureFlags(
              customerSelfService: true,
              returnsFromPos: false,
              qrProvider: qr,
              qrWebhook: false,
              debtPaymentsFromPos: false,
              fromServer: true,
            ),
          ),
          notificationsBadgeProvider.overrideWithValue((unread: 3, syncError: true)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('SCR-24/25: роль сессии и показ QR по QR_PROVIDER (клиенту — только onec, §24.4)', () {
      final ProviderContainer seller = container(RoleCode.seller, QrProviderMode.none);
      expect(seller.read(ordersViewerProvider).role, RoleCode.seller);
      expect(seller.read(ordersViewerProvider).canShowQr, isFalse);
      expect(container(RoleCode.cashier, QrProviderMode.bakai).read(ordersViewerProvider).canShowQr, isTrue);
      expect(container(RoleCode.customer, QrProviderMode.bakai).read(ordersViewerProvider).canShowQr, isFalse);
      expect(container(RoleCode.customer, QrProviderMode.onec).read(ordersViewerProvider).canShowQr, isTrue);
    });

    test('печать подключена; роль SCR-21 — из профиля; «Повторить заказ» скрыт у owner', () {
      final ProviderContainer owner = container(RoleCode.owner, QrProviderMode.onec);
      expect(owner.read(orderDocumentPrinterProvider), isNotNull);
      expect(owner.read(checkoutViewerRoleProvider), RoleCode.owner);
      expect(owner.read(orderRepeatPortProvider), isNull);
    });

    test('F-flutter-ui-4: роль SCR-26 — из профиля входа (customer.create.force у cashier/senior_seller/admin)', () {
      for (final RoleCode role in <RoleCode>[RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin]) {
        expect(container(role, QrProviderMode.onec).read(newCustomerViewerRoleProvider), role);
      }
      expect(container(RoleCode.seller, QrProviderMode.onec).read(newCustomerViewerRoleProvider), RoleCode.seller);
    });

    test('F-flutter-ui-1: блокировка корзины UI-20-020 подключена к ожиданию результата POST /orders', () {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          ...stageFOverrides,
          catalogViewerRoleProvider.overrideWithValue(RoleCode.seller),
          checkoutOnlineProvider.overrideWithValue(true),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(cartSubmissionLockedProvider), isFalse);
      expect(c.read(cartSubmissionOverlayProvider), isNotNull);
      expect(c.read(notificationAnnouncementsEnabledProvider), isTrue, reason: 'UI-44-011 в оболочке');
    });

    test('бейдж уведомлений каталога и popover; слоты баннеров SCR-20/21/24', () {
      final ProviderContainer c = container(RoleCode.seller, QrProviderMode.onec);
      expect(c.read(catalogUnreadNotificationsProvider), 3);
      expect(c.read(catalogSyncErrorNotificationProvider), isTrue);
      expect(c.read(catalogNotificationsPopoverProvider), isNotNull);
      expect(c.read(cartNotificationBannerProvider), isNotNull);
      expect(c.read(checkoutNotificationBannerProvider), isNotNull);
      expect(c.read(orderNotificationBannerProvider), isNotNull);
    });
  });
}
