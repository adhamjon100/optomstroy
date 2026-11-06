// Привязки режима «Планшет магазина» (P-002, ADR-115; 06 §6.2 «Размещение режима…» п. (3)–(4), §6.10 «Привязки корня
// в режиме «Планшет магазина»»; 13 TAB-2-01) для композиционного корня `app/di/overrides.dart`
// (`...kioskModeOverrides`), по образцу `customer_mode_bindings.dart` (SCR-50).
//
// Фича kiosk не импортирует фичи сверх DAG 06 §6.1 (`kiosk → catalog, cart, checkout`), а её саму не импортирует ни
// одна фича (FL-03). Корень связывает порты фичи kiosk (`features/kiosk/kiosk_providers.dart`) с реализациями:
// - тело витрины SCR-51 (`kioskCatalogBodyProvider`) → экран фичи catalog `kiosk_catalog_view.dart` (13 TAB-2-03);
//   порты витрины фичи catalog (`catalog_providers.dart`): логотип с аварийным выходом UI-51-017 (долгое нажатие 5 с —
//   `KioskEmergencyExitTrigger` фичи kiosk) и слой карточки товара UI-51-011 (SCR-14 в варианте покупателя из
//   публичных секций фичи product_details — catalog ↛ product_details, kiosk ↛ product_details);
// - шаги оформления SCR-52/SCR-53 (13 TAB-2-04): корзина для оформления `kioskCheckoutCartProvider` →
//   [KioskCheckoutCartPort] над корзиной фичи cart (kiosk ↛ cart/presentation); репозиторий `/kiosk/*` привязывает
//   `features/kiosk/data/kiosk_bindings.dart` (FL-06);
// - сброс FLOW-045 (13 TAB-2-05): «Начать заново» SCR-51 и «Готово» SCR-53 (`catalogKioskStartOverProvider`) →
//   оркестратор сброса фичи kiosk ([kioskStartOverPort]: `POST /kiosk/reset`, память покупателя, буфер обмена,
//   повторы без сети); автосброс по бездействию, гашение экрана и уход в фон — монитор в каркасе `KioskShellScreen`.
// Порты витрины действуют только на экранах режима планшета (G-15): каталог сотрудника и SCR-50 их не читают.
// Роль каталога и корзины `RoleCode.kiosk` для сессии `kind=kiosk` — `catalogViewerRole` в `app/di/overrides.dart`.
// Режимы сотрудников и покупателя этими привязками не меняются (01 GEN-256).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/features/cart/cart_providers.dart' as cart;
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/presentation/kiosk_cart_rejection.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart' show catalogOnlineStatusProvider;
import 'package:optomstroy/features/catalog/presentation/screens/kiosk_catalog_view.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_reset_orchestrator.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_sections.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/variant_picker_sheet.dart';

/// Тело витрины SCR-51 (`/kiosk?c=`). Строка поиска — только в памяти экрана, в адресе её нет (02 ч. F, правило 3).
Widget kioskCatalogBody(BuildContext context, KioskCatalogArgs args) => KioskCatalogView(categoryId: args.categoryId);

/// Логотип шапки витрины: долгое нажатие 5 с — аварийный выход UI-51-017 (P-002 §8.9 п. 2).
Widget kioskEmergencyLogo(Widget logo) => KioskEmergencyExitTrigger(child: logo);

/// Слой карточки товара витрины (UI-51-011).
Widget kioskProductDetails(BuildContext context, catalog.CatalogKioskProductArgs args) =>
    KioskProductDetailsBody(productId: args.productId, variantId: args.variantId);

/// Переопределения режима планшета (подключаются в `appOverrides`).
final List<Override> kioskModeOverrides = <Override>[
  kioskCatalogBodyProvider.overrideWithValue(kioskCatalogBody),
  catalog.catalogKioskLogoWrapperProvider.overrideWithValue(kioskEmergencyLogo),
  catalog.catalogKioskProductDetailsProvider.overrideWithValue(kioskProductDetails),
  catalog.catalogKioskStartOverProvider.overrideWith(kioskStartOverPort),
  kioskCheckoutCartProvider.overrideWith(kioskCheckoutCartFor),
];

/// Корзина для оформления SCR-52 — только у планшета (роль каталога и корзины `kiosk`); новый объект на каждое
/// поколение корзины планшета (`cartSyncProvider` — новый порт после сброса FLOW-045), поэтому сброс очищает и память
/// оформления (номер, `challengeId`, код, ключ).
KioskCheckoutCart? kioskCheckoutCartFor(Ref ref) {
  if (ref.watch(catalog.catalogViewerRoleProvider) != RoleCode.kiosk) return null;
  ref.watch(cart.cartSyncProvider);
  return KioskCheckoutCartPort(ref.container);
}

/// [KioskCheckoutCart] над корзиной фичи cart (`cartControllerProvider`): перед предпросмотром неподтверждённые
/// изменения отправляются; корзина — серверная корзина на экране (`id`, `rowVersion`). Чтения — через контейнер: объект
/// переживает пересборку провайдера порта, пока идёт запрос.
final class KioskCheckoutCartPort implements KioskCheckoutCart {
  const KioskCheckoutCartPort(this._container);

  final ProviderContainer _container;

  @override
  Future<KioskCartRef?> current() async {
    final CartController controller = _container.read(cartControllerProvider.notifier);
    if (_container.read(cartControllerProvider).hasUnconfirmed) await controller.flushNow();
    Cart? server = _container.read(cartControllerProvider).server;
    if (server == null) {
      await controller.refresh();
      server = _container.read(cartControllerProvider).server;
    }
    if (server == null || server.isEmpty) return null;
    return KioskCartRef(cartId: server.id, rowVersion: server.rowVersion);
  }

  @override
  Future<void> refresh() async {
    await _container.read(cartControllerProvider.notifier).refresh();
  }
}

/// Содержимое слоя карточки товара SCR-51 (02 UI-51-011; ADR-115 п. 22): SCR-14 в варианте покупателя — галерея,
/// название, цена с чипом «Обычные цены магазина», наличие по `customer_stock_display`, варианты (SCR-15 — лист),
/// количество и «В корзину» (SCR-16 — лист), характеристики и описание. Без таблицы складов, штрихкодов, кода 1С,
/// звезды избранного и «Недавних»; крошек и перехода в поиск сотрудника нет (маршруты `/catalog*` закрыты G-15).
/// Запросы карточки — без `warehouseId` (`ProductDetailsState.isCustomer` и склад корзины планшета — 13 TAB-2-12).
/// «В корзину», степпер и лист вариантов недоступны без связи (`offline`, `serverDown` — как у витрины), при `426` и
/// метке сброса без сети (`cartOrderingBlockedProvider`; 02 UI-51-010, AC-UI-51-006, AC-UI-51-009); отказ добавления —
/// снекбар без чисел сервера (`kioskCartRejectionText`). Состояние CTA карточки SCR-14 / SCR-50 не меняется.
class KioskProductDetailsBody extends ConsumerWidget {
  const KioskProductDetailsBody({required this.productId, this.variantId, super.key});

  /// Ключ содержимого (тесты).
  static const Key bodyKey = ValueKey<String>('kiosk-product-body');

  final String productId;
  final String? variantId;

  /// Нет связи для добавления: сети нет или сервер не отвечает (как «Нет связи» витрины SCR-51).
  static bool _noLink(OnlineStatus s) => s == OnlineStatus.offline || s == OnlineStatus.serverDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ProductDetailsArgs args = (productId: productId, variantId: variantId, qty: null);
    final ProductDetailsState s = ref.watch(productDetailsProvider(args));
    final ProductDetailsNotifier n = ref.read(productDetailsProvider(args).notifier);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool blocked = ref.watch(cart.cartOrderingBlockedProvider) || _noLink(ref.watch(catalogOnlineStatusProvider));
    ref.listen<Failure?>(productDetailsProvider(args).select((ProductDetailsState x) => x.addFailure), (
      Failure? previous,
      Failure? next,
    ) {
      if (next == null || identical(next, previous)) return;
      final ProductDetailsState now = ref.read(productDetailsProvider(args));
      final String message =
          kioskCartRejectionText(
            l10n,
            next,
            minQuantity: now.rules.minQuantity,
            multiple: now.rules.multiplicity,
            unit: now.baseUnit?.label ?? '',
          ) ??
          l10n.error_internal;
      AppSnackbar.show(context, message: message, variant: AppSnackbarVariant.error);
    });
    final Widget body = switch (s.status) {
      ProductLoadStatus.loading => const SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: ProductDetailsSkeleton(),
      ),
      ProductLoadStatus.notFound => Center(
        child: EmptyState(variant: EmptyStateVariant.search, title: l10n.product_not_found_title),
      ),
      ProductLoadStatus.error => Center(
        child: ErrorState.fullScreen(
          title: s.failure is NetworkFailure ? l10n.global_offline_title : l10n.ds_server_down,
          message: l10n.error_internal,
          onRetry: n.retry,
          requestId: s.failure?.requestId,
        ),
      ),
      ProductLoadStatus.ready => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) =>
            _ready(context, s, n, twoColumns: box.maxWidth >= 560, blocked: blocked),
      ),
    };
    return KeyedSubtree(key: bodyKey, child: body);
  }

  Widget _ready(
    BuildContext context,
    ProductDetailsState s,
    ProductDetailsNotifier n, {
    required bool twoColumns,
    required bool blocked,
  }) {
    Future<void> variants() => showVariantPickerSheet(context, state: s, notifier: n, addBlocked: blocked);
    final Widget? err = s.failure == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ErrorState.inline(message: AppLocalizations.of(context).error_internal, onRetry: n.retry),
          );
    final List<Widget> info = <Widget>[
      ?err,
      ProductMainInfo(state: s, notifier: n, onOpenVariantList: variants),
      const SizedBox(height: 16),
      ProductQuantityBar(state: s, notifier: n, addBlocked: blocked),
      const SizedBox(height: 24),
      ProductSpecsSection(state: s),
      const SizedBox(height: 16),
      ProductDescriptionSection(state: s),
    ];
    if (!twoColumns) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: <Widget>[
          ProductGallerySection(state: s),
          const SizedBox(height: 16),
          ...info,
        ],
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 2, child: ProductGallerySection(state: s)),
          const SizedBox(width: 24),
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: info),
          ),
        ],
      ),
    );
  }
}
