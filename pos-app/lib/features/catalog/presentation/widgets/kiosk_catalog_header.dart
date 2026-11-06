// Шапка витрины планшета магазина — SCR-51 зона A (02 ч. F SCR-51.2, UI-51-001…UI-51-006; ADR-115 п. 8; ADR-114 П.1).
//
// `TopAppBarPos.full` в раскладке ADR-114 со слотами «☰», `SyncIndicator`, часов, колокольчика и блока пользователя
// пустыми (новый вариант шапки не вводится): логотип (знак 38 + «Оптомстрой» 21/700; тап — без действия, долгое
// нажатие 5 с — аварийный выход через порт корня) → `SearchBar.header` без кнопки сканера → правая группа: чип
// «Обычные цены магазина» → «Начать заново» → кнопка корзины (порт `catalogCartButtonProvider`, drawer 420).
// Сжатие по ширине — ступени `TopAppBarFit` шапки: вместе со словом «Оптомстрой» первым сворачивается текст чипа (остаётся
// иконка с тултипом и `Semantics`), вместе со строкой «Корзина» — подпись «Начать заново» (остаётся иконка
// `restart_alt` с тултипом); кнопка корзины и поиск не скрываются, при нехватке места поиск уходит второй строкой.
// Поле поиска строит экран (контроллер, debounce); приватный ввод (без подсказок, автоисправления, обучения клавиатуры,
// выделения и вставки) поле получает само от `PrivateInputScope` режима планшета (03 §9.74, DS-099).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';

/// Шапка SCR-51 (UI-51-001).
class KioskCatalogHeader extends ConsumerWidget {
  const KioskCatalogHeader({
    super.key,
    required this.windowClass,
    required this.search,
    required this.onStartOver,
    this.startingOver = false,
  });

  /// Ключ логотипа (тесты: долгое нажатие — аварийный выход).
  static const Key logoKey = ValueKey<String>('kiosk-header-logo');

  /// Ключ чипа «Обычные цены магазина».
  static const Key priceChipKey = ValueKey<String>('kiosk-price-chip');

  /// Ключ «Начать заново».
  static const Key startOverKey = ValueKey<String>('kiosk-start-over');

  final WindowClass windowClass;

  /// Поле поиска (`SearchBar.header` без сканера) — строит экран.
  final Widget search;

  /// «Начать заново» (UI-51-005); `null` — недоступна.
  final VoidCallback? onStartOver;

  /// Сброс идёт — кнопка в загрузке, повторные нажатия не принимаются.
  final bool startingOver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CatalogKioskLogoWrapper? wrap = ref.watch(catalogKioskLogoWrapperProvider);
    final WidgetBuilder? cartButton = ref.watch(catalogCartButtonProvider);
    // Тап по логотипу — без действия (на планшете логотип не ведёт в каталог сотрудника); подсказки о долгом нажатии
    // на экране нет (02 UI-51-002).
    const Widget logo = KeyedSubtree(key: logoKey, child: CatalogLogo.header());
    return TopAppBarPos(
      windowClass: windowClass,
      logo: wrap == null ? logo : wrap(logo),
      search: search,
      actions: <Widget>[
        const KioskPriceChip(key: priceChipKey),
        KioskStartOverButton(key: startOverKey, onPressed: onStartOver, loading: startingOver),
        if (cartButton != null) Builder(builder: cartButton),
      ],
      // Колокольчика, блока пользователя, «☰», `SyncIndicator` и часов у планшета нет (02 UI-51-001, ADR-115 п. 8).
    );
  }
}

/// Чип «Обычные цены магазина» (UI-51-004; KIOSK-006, Р-05 (а)): `StatusChip` вида цены (иконка `sell`) без предела
/// ширины текста 160 — текст целиком (AC-UI-51-019: 1280 × 800 без обрезки); тап — без действия; тултип и `Semantics`
/// — `kiosk_price_chip`. Текст или целиком, или никак: на узкой шапке (ступень `TopAppBarFit` без wordmark) — только
/// иконка с тултипом.
class KioskPriceChip extends StatelessWidget {
  const KioskPriceChip({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String label = l10n.kiosk_price_chip;
    if (TopAppBarFit.of(context).wordmark) {
      return StatusChip(
        label: label,
        variant: StatusChipVariant.priceList,
        tooltip: label,
        semanticLabel: label,
        maxLabelWidth: null,
      );
    }
    final DsColors c = context.colors;
    final (Color bg, Color fg) = StatusChip.colorsOf(c, StatusChipVariant.priceList);
    return AppTooltip(
      message: label,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Container(
          key: const ValueKey<String>('kiosk-price-chip-icon'),
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.full)),
          child: Icon(StatusChip.iconOf(StatusChipVariant.priceList), size: 16, color: fg),
        ),
      ),
    );
  }
}

/// «Начать заново» (UI-51-005): `AppButton.outlined M` с иконкой `restart_alt`; на узкой шапке — иконка с тултипом.
/// Состояния: загрузка (сброс идёт), недоступна ([onPressed] `null`).
class KioskStartOverButton extends StatelessWidget {
  const KioskStartOverButton({super.key, required this.onPressed, this.loading = false});

  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String label = l10n.kiosk_start_over;
    final VoidCallback? tap = loading ? null : onPressed;
    if (TopAppBarFit.of(context).cartLabel) {
      return AppButton(
        label: label,
        icon: Icons.restart_alt_rounded,
        variant: AppButtonVariant.outlined,
        loading: loading,
        onPressed: tap,
      );
    }
    return AppIconButton(
      icon: Icons.restart_alt_rounded,
      semanticLabel: label,
      tooltip: label,
      loading: loading,
      onPressed: tap,
    );
  }
}
