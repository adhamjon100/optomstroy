// Стенд экранов режима «Планшет магазина» SCR-51 «Витрина и корзина», SCR-52 «Оформление заявки», SCR-53 «Заявка
// отправлена» для golden T-KIOSK-010 (`golden/kiosk_golden_test.dart`) и проверок доступности AC-A11Y-023
// (`kiosk_a11y_test.dart`).
//
// Экраны — настоящие маршруты режима `kioskRoutes()` в каркасе `KioskShellScreen`, тело витрины и привязки витрины —
// из `app/router/shells/kiosk_mode_bindings.dart` (логотип с аварийным выходом, слой карточки); кнопка корзины шапки —
// `CartHeaderButtonView` на фейковой корзине (как корень `app/di/overrides.dart`). Фейки — каталог
// (`catalog/presentation/support/catalog_fakes.dart`), корзина (`cart/support/cart_test_support.dart`), оформление
// заявки (`kiosk/checkout/kiosk_checkout_support.dart`). Таймер бездействия выключен большим `kiosk_idle_seconds`.
// Палитра B, reduce-motion, синтетические данные: номера — шаблон `+996 555 000 xxx`, имён людей нет.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/app/router/shells/kiosk_mode_bindings.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_screen.dart';
import 'package:optomstroy/core/session/session_overlay.dart' show KioskStatus, kioskStatusProvider;
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/cart_panel.dart' show CartPanelVariant;
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart' show CartPanelView;
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

import '../../support/f_fakes.dart' show FakeCartRepository;
import '../cart/support/cart_test_support.dart' as cs;
import '../catalog/presentation/support/catalog_fakes.dart' as cf;
import 'checkout/kiosk_checkout_support.dart' as ks;

/// Окна режима планшета (AC-UI-51-019; 12 T-KIOSK-010): горизонтально и вертикально.
const Map<String, Size> kioskWindows = <String, Size>{'expanded': Size(1280, 800), 'medium': Size(800, 1280)};

/// Позиции корзины планшета (обычные цены, без клиента и скидки): 3 позиции · 10 шт, 12 350,00 сом.
final List<CartLine> _lines = <CartLine>[
  cs.canonLine('sl1001', 'Унитаз-компакт Sanita Luxe Classic', 'SL1001', 1, 8450),
  cs.canonLine('sf450', 'Сифон для раковины бутылочный хром', 'SF450', 2, 1250),
  cs.canonLine('kt110', 'Тройник канализационный 110 мм', 'KT110', 7, 200),
];

/// Сумма корзины стенда — целые тыйыны (D-19).
const Money kioskStandTotal = Money(1235000);

Cart _cart() => Cart(
  id: ks.kCartId,
  status: CartStatus.active,
  items: _lines,
  rowVersion: 18,
  warehouseId: 'wh-main',
  itemsCount: _lines.length,
  subtotal: kioskStandTotal,
  total: kioskStandTotal,
);

/// Копия корзины на устройстве (как в cart_golden_test): строки подтверждены сервером.
CartLocalSnapshot _local(Cart cart) => CartLocalSnapshot(
  localCartId: 'local-kiosk',
  dirty: false,
  baseRowVersion: cart.rowVersion,
  lines: <CartLocalLine>[
    for (final (int i, CartLine l) in cart.items.indexed)
      CartLocalLine(
        key: CartLineKey(l.variantId),
        quantity: l.quantity.value,
        syncState: CartDraftSyncState.synced,
        lineNo: i + 1,
        unitId: 'u-pc',
        unitLabel: 'шт',
        step: Qty.units(1),
      ),
  ],
);

/// Предпросмотр SCR-52 по той же корзине (`POST /cart/checkout-preview`: `cash`, `pickup`).
CheckoutPreview _preview() => CheckoutPreview(
  cartId: ks.kCartId,
  cartRowVersion: 18,
  ok: true,
  items: <OrderLine>[
    for (final (int i, CartLine l) in _lines.indexed)
      OrderLine(lineNo: i + 1, variantId: l.variantId, quantity: l.quantity),
  ],
  subtotal: kioskStandTotal,
  total: kioskStandTotal,
  totalToPay: kioskStandTotal,
  paymentMethod: PaymentMethod.cash,
  previewToken: 'pv-18',
);

/// Товары «Сантехники» (стартовый корень — с наибольшим числом товаров): обычная цена, наличие без чисел (`status`).
List<ProductSummary> _products() => <ProductSummary>[
  for (final (int i, String name, String sku, int som, StockLevel level) in <(int, String, String, int, StockLevel)>[
    (1, 'Унитаз-компакт Sanita Luxe Classic', 'SL1001', 8450, StockLevel.inStock),
    (2, 'Раковина накладная Kirovit KVM-021', 'KVM021', 3120, StockLevel.inStock),
    (3, 'Ванна акриловая AquaLine 170x70', 'AL17070', 12950, StockLevel.low),
    (4, 'Душевая кабина River 90x90', 'RV9090', 18600, StockLevel.inStock),
    (5, 'Инсталляция для унитаза Geberit Duofix', 'GD112', 14320, StockLevel.inStock),
    (6, 'Сифон для раковины бутылочный хром', 'SF450', 1250, StockLevel.inStock),
    (7, 'Тумба с раковиной 60 см белая', 'TR600', 15900, StockLevel.out),
    (8, 'Тройник канализационный 110 мм', 'KT110', 200, StockLevel.inStock),
  ])
    cf.product(i, name: name, sku: sku, priceSom: som, level: level, hideQty: true),
];

/// «+ Добавить» витрины: в кадре не нажимается.
final class _QuietCart implements CatalogCartPort {
  @override
  Future<Result<void>> add(ProductSummary product) async => const Success<void>(null);

  @override
  String? rejectionText(Failure failure, AppLocalizations l10n) => null;
}

/// Порт `FLAG_SECURE`: без платформы.
final class _NoSecureScreen implements SecureScreen {
  @override
  Future<void> setSecure({required bool enabled}) async {}
}

/// Стенд одного кадра: свежие фейки и маршрутизатор на каждый прогон.
final class KioskScreensStand {
  /// [drawer] — над витриной открыт drawer корзины 420 (SCR-51, AC-UI-51-007); [status] — состояние сессии планшета
  /// (по умолчанию готова; полноэкранные состояния UI-51-015 — `KioskStateView`).
  KioskScreensStand({bool drawer = false, KioskStatus status = KioskStatus.ready}) {
    final cf.FakeCatalogRepository catalog = cf.FakeCatalogRepository(tree: cf.designCategoryTree())
      ..networkPages.add(Success<CatalogPage<ProductSummary>>(cf.page(_products(), total: 12)));
    final FakeCartRepository repo = FakeCartRepository();
    final cs.FakeCartSync sync = cs.FakeCartSync(repo);
    final Cart cart = _cart();
    cs.serveCart(repo, cart);
    sync.snapshot = _local(cart);
    checkout.checkout.fallback = Success<CheckoutPreview>(_preview());
    overrides = <Override>[
      ...checkout.overrides(withCart: true),
      // Витрина (как `kioskModeOverrides` корня) на фейках каталога.
      kioskCatalogBodyProvider.overrideWithValue(drawer ? _showcaseWithDrawer : kioskCatalogBody),
      catalogKioskLogoWrapperProvider.overrideWithValue(kioskEmergencyLogo),
      catalogKioskProductDetailsProvider.overrideWithValue(kioskProductDetails),
      catalogKioskStartOverProvider.overrideWithValue(() async {}),
      catalogRepositoryProvider.overrideWithValue(catalog),
      searchRepositoryProvider.overrideWithValue(cf.FakeSearchRepository()),
      catalogViewerRoleProvider.overrideWithValue(RoleCode.kiosk),
      catalogShelfPortProvider.overrideWithValue(null),
      catalogOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
      catalogCustomerStockDisplayProvider.overrideWithValue(CustomerStockDisplay.status),
      catalogCartPortProvider.overrideWithValue(_QuietCart()),
      catalogCartButtonProvider.overrideWithValue((BuildContext context) => const CartHeaderButtonView()),
      catalogUserSettingsStoreProvider.overrideWithValue(null),
      // Корзина планшета (роль `kiosk`: без клиента, склада, скидки и «Отложить»).
      cartSyncProvider.overrideWithValue(sync),
      cartRepositoryProvider.overrideWithValue(repo),
      cartViewerRoleProvider.overrideWithValue(RoleCode.kiosk),
      cartViewerUserIdProvider.overrideWithValue('kiosk-user'),
      cartOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
      cartOrderingBlockedProvider.overrideWithValue(false),
      // Режим: сессия планшета готова; таймер бездействия в кадр не попадает.
      kioskStatusProvider.overrideWithValue(status),
      kioskTimingsProvider.overrideWithValue(const KioskTimings(idle: Duration(minutes: 30))),
      secureScreenProvider.overrideWithValue(_NoSecureScreen()),
    ];
  }

  final ks.KioskCheckoutFakes checkout = ks.KioskCheckoutFakes();
  late final List<Override> overrides;
  final GoRouter router = GoRouter(initialLocation: KioskPaths.showcase, routes: kioskRoutes());

  Widget app(Size size, {double textScale = 1}) => SizedBox(
    width: size.width,
    height: size.height,
    child: ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        // Как `App` в режиме планшета: приватный ввод во всём приложении (03 §9.74); reduce-motion.
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            disableAnimations: true,
            padding: EdgeInsets.zero,
            textScaler: TextScaler.linear(textScale),
          ),
          child: ProductImageScope(
            providerFor: cf.transparentImage,
            child: PrivateInputScope(child: child!),
          ),
        ),
      ),
    ),
  );
}

/// Витрина с открытым drawer корзины. Сам `CartDrawer.open` кладёт маршрут в корневой навигатор — в golden это
/// навигатор обвязки alchemist вне приложения (без локализаций и `ProviderScope`), поэтому drawer собран так же, как
/// `_CartDrawerPage`: затемнение и панель `CartPanelView(overlay)` шириной 420 справа (как cart_golden_test).
Widget _showcaseWithDrawer(BuildContext context, KioskCatalogArgs args) => Stack(
  fit: StackFit.expand,
  children: <Widget>[
    kioskCatalogBody(context, args),
    ColoredBox(color: context.colors.overlay),
    const Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SizedBox(
        width: DsBreakpoints.cartDrawer,
        height: double.infinity, // money-double: allow — высота drawer (lp), не деньги
        child: Material(
          type: MaterialType.transparency,
          child: CartPanelView(variant: CartPanelVariant.overlay),
        ),
      ),
    ),
  ],
);
