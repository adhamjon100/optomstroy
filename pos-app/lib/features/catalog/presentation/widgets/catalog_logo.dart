// Логотип шапки каталога (02 UI-10-001; 03 §9.53 `SplashLogo.header`; ядро v1.9 §24.1): оранжевый знак
// `assets/brand/logo_orange.png` + wordmark. Копия по образцу `AuthLogo` (фича auth недоступна
// каталогу по DAG 06 §6.1; перенос в design_system — 03 §9.53). Тап — корень ветки «Каталог». Кнопка доступна с
// клавиатуры (Tab, Enter/Space) с кольцом фокуса и действием «нажать» для экранного диктора (A11Y-009, WCAG 2.1.1,
// 4.1.2).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart' show TopAppBarFit;
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Путь знака бренда (объявлен в pubspec).
const String kCatalogBrandMarkAsset = 'assets/brand/logo_orange.png';

/// Wordmark — название продукта, не переводится (как `kBrandWordmark` фичи auth; ключа ARB нет).
const String kCatalogBrandWordmark = 'Оптомстрой';

class CatalogLogo extends StatelessWidget {
  const CatalogLogo({super.key, this.markSize = 32, this.wordmark = true, this.onTap}) : header = false;

  /// Логотип шапки `TopAppBarPos.full` (прототип 2026-10-29, ADR-112): знак 38, зазор 12, «Оптомстрой» `h3 700`.
  /// В шапке «Оптомстрой» сворачивается по её ширине (`TopAppBarFit.wordmark`) — остаётся знак.
  const CatalogLogo.header({super.key, this.wordmark = true, this.onTap}) : markSize = 38, header = true;

  final double markSize; // money-double: allow — геометрия UI (lp)
  final bool wordmark;
  final VoidCallback? onTap;

  /// Стиль шапки medium+ (wordmark `h3 700`, зазор 12).
  final bool header;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1; // money-double: allow — геометрия UI (lp)
    final bool wordmark = this.wordmark && TopAppBarFit.of(context).wordmark;
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Image.asset(
          kCatalogBrandMarkAsset,
          width: markSize,
          height: markSize,
          cacheWidth: (markSize * dpr).ceil(),
          filterQuality: FilterQuality.medium,
          errorBuilder: (BuildContext context, Object error, StackTrace? stack) => SizedBox.square(dimension: markSize),
        ),
        if (wordmark) ...<Widget>[
          SizedBox(width: header ? context.space.s3 : context.space.s2),
          Text(
            kCatalogBrandWordmark,
            maxLines: 1,
            style: header
                ? context.text.h3.copyWith(fontWeight: FontWeight.w700, color: context.colors.textPrimary)
                : context.text.title.copyWith(fontWeight: FontWeight.w600, color: context.colors.textPrimary),
          ),
        ],
      ],
    );
    final VoidCallback? tap = onTap;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);
    return Semantics(
      button: tap != null,
      label: AppLocalizations.of(context).splash_logo_a11y,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: tap,
      child: tap == null
          ? row
          : DsInteractive(
              onTap: tap,
              builder: (BuildContext context, DsInteractionState s) =>
                  DsFocusRing(visible: s.focused, borderRadius: radius, child: row),
            ),
    );
  }
}
