// `SplashLogo` вариант `splash` (03 §9.53, §12; ANIM-001; ядро v1.9 §24.1): оранжевый знак
// `assets/brand/logo_orange.png` на белом + wordmark; знак opacity 0→1 и scale .92→1 за 600 мс
// (`ds.motion.splashLogo`, `emphasized`), wordmark — с 120 мс; reduce-motion — crossfade 80 мс
// без scale. Нет asset → только wordmark (SplashLogo.empty). Компонент DS п. 9.53 — до переноса
// в design_system живёт в фиче splash (06 §6.1: splash не зависит от auth).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

/// Знак (копия `resursi/Logo Orange.png`; декодируется в размер виджета).
const String kSplashMarkAsset = 'assets/brand/logo_orange.png';

/// Wordmark — название продукта не переводится (ключа ARB нет; см. D_spec_questions RM-D-007).
const String kSplashWordmark = 'Оптомстрой';

/// Тег `Hero` знака Splash → `SplashLogo.auth` на SCR-01 (ANIM-028).
const String kSplashHeroTag = 'splash_logo';

class SplashLogo extends StatefulWidget {
  const SplashLogo({super.key});

  static const Key markKey = Key('splash-logo-mark');
  static const Key wordmarkKey = Key('splash-logo-wordmark');

  @override
  State<SplashLogo> createState() => _SplashLogoState();
}

class _SplashLogoState extends State<SplashLogo> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c == null) {
      final bool reduce = context.motion.reduceMotion;
      final AnimationController c = AnimationController(
        vsync: this,
        duration: reduce ? context.motion.reducedCrossfade : context.motion.splashLogo,
      );
      _c = c;
      unawaited(c.forward());
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduce = context.motion.reduceMotion;
    final bool large = context.windowClass != WindowClass.compact;
    final double size = large ? 128 : 96; // money-double: allow — геометрия UI (lp)
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1; // money-double: allow — геометрия UI (lp)
    final AnimationController c = _c!;
    final Animation<double /* money-double: allow — анимация UI */> markOpacity = CurvedAnimation(
      parent: c,
      curve: context.motion.emphasized,
    );
    // Wordmark стартует через 120 мс из 600 (интервал 0.2…1.0).
    final Animation<double> wordOpacity = // money-double: allow — анимация UI
    reduce
        ? markOpacity
        : CurvedAnimation(
            parent: c,
            curve: Interval(0.2, 1, curve: context.motion.emphasized),
          );
    Widget mark = Image.asset(
      kSplashMarkAsset,
      key: SplashLogo.markKey,
      width: size,
      height: size,
      cacheWidth: (size * dpr).ceil(),
      filterQuality: FilterQuality.medium,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) => SizedBox.square(dimension: size),
    );
    mark = FadeTransition(
      opacity: markOpacity,
      child: reduce
          ? mark
          : ScaleTransition(
              scale: Tween<double>(begin: 0.92, end: 1).animate(markOpacity), // money-double: allow — анимация UI
              child: mark,
            ),
    );
    return Semantics(
      image: true,
      label: AppLocalizations.of(context).splash_logo_a11y,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Hero(tag: kSplashHeroTag, child: mark),
            SizedBox(height: context.space.s4),
            FadeTransition(
              opacity: wordOpacity,
              child: Text(
                kSplashWordmark,
                key: SplashLogo.wordmarkKey,
                style: (large ? context.text.h1 : context.text.h2).copyWith(
                  fontWeight: FontWeight.w700,
                  color: context.colors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
