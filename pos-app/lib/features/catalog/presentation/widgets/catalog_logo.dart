// Логотип шапки каталога (02 UI-10-001; 03 §9.53 `SplashLogo.header`; ядро v1.9 §24.1): оранжевый знак
// `assets/brand/logo_orange.png` + wordmark. Копия по образцу `AuthLogo` (фича auth недоступна
// каталогу по DAG 06 §6.1; перенос в design_system — 03 §9.53). Тап — корень ветки «Каталог».
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Путь знака бренда (объявлен в pubspec).
const String kCatalogBrandMarkAsset = 'assets/brand/logo_orange.png';

/// Wordmark — название продукта, не переводится (как `kBrandWordmark` фичи auth; ключа ARB нет).
const String kCatalogBrandWordmark = 'Оптомстрой';

class CatalogLogo extends StatelessWidget {
  const CatalogLogo({super.key, this.markSize = 32, this.wordmark = true, this.onTap});

  final double markSize; // money-double: allow — геометрия UI (lp)
  final bool wordmark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1; // money-double: allow — геометрия UI (lp)
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
          SizedBox(width: context.space.s2),
          Text(
            kCatalogBrandWordmark,
            maxLines: 1,
            style: context.text.title.copyWith(fontWeight: FontWeight.w600, color: context.colors.textPrimary),
          ),
        ],
      ],
    );
    return Semantics(
      button: onTap != null,
      label: AppLocalizations.of(context).splash_logo_a11y,
      excludeSemantics: true,
      child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: row),
    );
  }
}
