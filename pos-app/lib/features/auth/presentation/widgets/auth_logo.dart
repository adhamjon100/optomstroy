// Логотип экранов входа — `SplashLogo.auth` / `.header` (03 §9.53; ядро v1.9 §24.1):
// оранжевый знак `assets/brand/logo_orange.png` (цвет из asset, не перекрашивается) +
// wordmark. Компонент DS п. 9.53; до переноса в design_system — копия в фичах auth и splash
// (DAG 06 §6.1 не допускает зависимость auth ↔ splash). Нет asset → только wordmark.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Путь растрового знака (копия `resursi/Logo Orange.png`, 8334 px; декодируется в размер виджета).
const String kBrandMarkAsset = 'assets/brand/logo_orange.png';

/// Wordmark — название продукта не переводится (ключа ARB нет, см. D_spec_questions RM-D-007;
/// так же — `MaterialApp.title` в app/app.dart).
const String kBrandWordmark = 'Оптомстрой';

/// Тег `Hero` логотипа Splash → SCR-01 (ANIM-028).
const String kSplashLogoHeroTag = 'splash_logo';

class AuthLogo extends StatelessWidget {
  const AuthLogo({super.key, this.markSize = 48, this.wordmark = true, this.wordmarkStyle, this.hero = true});

  final double markSize; // money-double: allow — геометрия UI (lp)
  final bool wordmark;
  final TextStyle? wordmarkStyle;

  /// Участвует в `Hero` с логотипом Splash.
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1; // money-double: allow — геометрия UI (lp)
    final Widget mark = Image.asset(
      kBrandMarkAsset,
      width: markSize,
      height: markSize,
      cacheWidth: (markSize * dpr).ceil(),
      filterQuality: FilterQuality.medium,
      // Пока asset не объявлен в pubspec (deps_requested RM-D-007) — пустое место того же размера.
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) => SizedBox.square(dimension: markSize),
    );
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (hero) Hero(tag: kSplashLogoHeroTag, child: mark) else mark,
        if (wordmark) ...<Widget>[
          SizedBox(width: context.space.s2),
          Flexible(
            child: Text(
              kBrandWordmark,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (wordmarkStyle ?? context.text.h3).copyWith(color: context.colors.textPrimary),
            ),
          ),
        ],
      ],
    );
    return Semantics(
      image: true,
      label: AppLocalizations.of(context).splash_logo_a11y,
      child: ExcludeSemantics(child: row),
    );
  }
}
