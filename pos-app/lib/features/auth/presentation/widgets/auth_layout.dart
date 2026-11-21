// Каркас экранов входа SCR-01/02/08 (02 §0.1; 03 §13.2; ядро §17.5, §18.2 п.15):
// compact — белый `surface` без карточки (поля 16 от края); medium — фон `background`
// + карточка 480 (`ds.radius.xl` 20, `elevation.2`, отступ 24); expanded ≥ 1024 — бренд-панель
// 560 (`surfaceVariant`: логотип, «Рабочее место продавца», персонаж 200, 4 преимущества —
// скрыты при высоте < 720, «Ваши данные защищены») + карточка 480. Вне AdaptiveScaffold.
// Персонаж зависит от высоты окна (02 SCR-08.2 compact `cold` «скрыт при высоте < 640»): compact и medium — скрыт при
// высоте < 640; medium при высоте < 820 — не больше 96.
// Ландшафт малой высоты (телефон лёжа, окно браузера с масштабом 200 %; [AuthLayout.isShortLandscape]): экран, который
// передал [AuthLayout.aside] и [AuthLayout.input], строится в две колонки — слева шапка, персонаж 96 (скрыт при высоте
// < 480), личность и второстепенные кнопки, справа — блок ввода (PIN с нампадом, ячейки кода) со своей прокруткой; так
// точки и нампад видны без прокрутки. Правило 02 SCR-01.12 (две колонки, персонаж 96 слева), распространённое на SCR-02
// и SCR-08 по указанию владельца 2026-11-18 об адаптивности (15 §5.8) — [ВЫВОД исполнителя]; large (≥ 1600) — как было.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/auth/presentation/widgets/auth_logo.dart';

/// Размер персонажа в текущем окне; `null` — персонаж скрыт (клавиатура и высота < 640).
typedef MascotSlotBuilder =
    Widget Function(BuildContext context, double size); // money-double: allow — геометрия UI (lp)

class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.body,
    this.mascot,
    this.banners = const <Widget>[],
    this.leading,
    this.keyboardMascotSize = 96,
    this.compactMascotSize = 160,
    this.mediumMascotSize = 200,
    required this.footerYear,
    this.backgroundOverride,
    this.aside,
    this.input,
  });

  /// Окно-ландшафт малой высоты: шире своей высоты, высота < 760, ширина ≥ 600 (телефон лёжа; 1920×1080 при масштабе
  /// браузера 200 % — 960×540).
  static bool isShortLandscape(Size size) => size.width > size.height && size.height < 760 && size.width >= 600;

  /// Ключ левой колонки ландшафта (личность, второстепенные кнопки).
  static const Key landscapeAsideKey = Key('auth-landscape-aside');

  /// Ключ правой колонки ландшафта (блок ввода).
  static const Key landscapeInputKey = Key('auth-landscape-input');

  /// Ширина карточки формы SCR-01/02/08.
  static const double cardWidth = 480; // money-double: allow — геометрия UI (lp)

  /// Ширина бренд-панели expanded.
  static const double brandPanelWidth = 560; // money-double: allow — геометрия UI (lp)

  /// Ключ бренд-панели (тесты брейкпоинта expanded).
  static const Key brandPanelKey = Key('auth-brand-panel');

  /// Ключ карточки формы (medium+).
  static const Key cardKey = Key('auth-card');

  /// Ключ блока «4 преимущества».
  static const Key featuresKey = Key('auth-brand-features');

  /// Ключ кнопки «Техническая поддержка».
  static const Key supportKey = Key('auth-support');

  /// Поля формы (заголовок, поле, кнопки) — без персонажа.
  final Widget body;
  final MascotSlotBuilder? mascot;

  /// Баннеры над формой (UI-01-011/012/017).
  final List<Widget> banners;

  /// Кнопка «назад» в шапке (SCR-02).
  final Widget? leading;

  /// Размер персонажа на compact при открытой клавиатуре (96 — SCR-01/08, 72 — SCR-02).
  final double keyboardMascotSize; // money-double: allow — геометрия UI (lp)

  /// Размер персонажа compact без клавиатуры (160; SCR-08 — 96).
  final double compactMascotSize; // money-double: allow — геометрия UI (lp)

  /// Размер персонажа medium (200; SCR-08 — 160).
  final double mediumMascotSize; // money-double: allow — геометрия UI (lp)

  /// Год футера «© {year} Оптомстрой» — год магазина Asia/Bishkek по `clockProvider` экрана.
  final int footerYear;

  /// Фон вместо `surface`/`background` (overlay SCR-08).
  final Color? backgroundOverride;

  /// Ландшафт малой высоты: левая колонка — заголовок, личность, второстепенные кнопки. Задаётся вместе с [input];
  /// вне ландшафта не используется — там [body] (одна колонка, порядок экрана прежний).
  final Widget? aside;

  /// Ландшафт малой высоты: правая колонка — блок ввода (поле PIN с нампадом, ячейки кода, кнопки шага).
  final Widget? input;

  @override
  Widget build(BuildContext context) {
    final WindowClass wc = context.windowClass;
    final Size size = MediaQuery.sizeOf(context);
    if (aside != null && input != null && wc != WindowClass.large && isShortLandscape(size)) {
      return _landscape(context, size);
    }
    return switch (wc) {
      WindowClass.compact => _compact(context),
      WindowClass.medium => _medium(context),
      WindowClass.expanded || WindowClass.large => _expanded(context),
    };
  }

  double /* money-double: allow — геометрия UI */ ? _compactMascotSize(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final bool keyboard = mq.viewInsets.bottom > 0;
    if (mq.size.height < 640) {
      return null;
    }
    return keyboard ? keyboardMascotSize : compactMascotSize;
  }

  /// medium: скрыт при высоте < 640, при высоте < 820 — не больше 96.
  double /* money-double: allow — геометрия UI */ ? _mediumMascotSize(BuildContext context) {
    final double h = MediaQuery.sizeOf(context).height; // money-double: allow — геометрия UI (lp)
    if (h < 640) {
      return null;
    }
    return h < 820 ? math.min(mediumMascotSize, 96) : mediumMascotSize;
  }

  Widget _header(BuildContext context, {required bool compact}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Row(
      children: <Widget>[
        ?leading,
        if (leading != null) SizedBox(width: context.space.s2),
        // medium с «← Изменить номер» (SCR-02): слева — назад, справа — поддержка, без логотипа.
        if (compact || leading == null)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: AuthLogo(markSize: 32, wordmarkStyle: context.text.title),
            ),
          )
        else
          const Spacer(),
        if (compact)
          AppIconButton(
            key: supportKey,
            icon: Icons.help_outline_rounded,
            semanticLabel: l10n.auth_support_title,
            onPressed: () => showAuthSupport(context),
          )
        else
          Flexible(
            child: AppButton(
              key: supportKey,
              label: l10n.auth_support_title,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              onPressed: () => showAuthSupport(context),
            ),
          ),
      ],
    );
  }

  Widget _mascot(BuildContext context, double /* money-double: allow — геометрия UI */ ? size) {
    if (mascot == null || size == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.only(bottom: context.space.s6),
      child: Center(child: mascot!(context, size)),
    );
  }

  Widget _compact(BuildContext context) {
    final DsColors c = context.colors;
    return Scaffold(
      backgroundColor: backgroundOverride ?? c.surface,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.space.s4),
              child: SizedBox(height: 56, child: _header(context, compact: true)),
            ),
            ...banners,
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s6, context.space.s4, context.space.s4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[_mascot(context, _compactMascotSize(context)), body],
                ),
              ),
            ),
            _Footer(year: footerYear),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) {
    final DsColors c = context.colors;
    return Container(
      key: cardKey,
      width: cardWidth,
      padding: EdgeInsets.all(context.space.s6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.all(context.radii.xl),
        boxShadow: context.elevation.e2,
      ),
      child: child,
    );
  }

  Widget _medium(BuildContext context) {
    final DsColors c = context.colors;
    return Scaffold(
      backgroundColor: backgroundOverride ?? c.background,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            ...banners,
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(context.space.s6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _card(
                        context,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _header(context, compact: false),
                            SizedBox(height: context.space.s6),
                            _mascot(context, _mediumMascotSize(context)),
                            body,
                          ],
                        ),
                      ),
                      SizedBox(height: context.space.s4),
                      _Footer(year: footerYear, padded: false),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ландшафт малой высоты: две колонки по половине ширины, поля 16; карточка — только при высоте ≥ 600.
  Widget _landscape(BuildContext context, Size size) {
    final DsColors c = context.colors;
    final bool card = size.height >= 600;
    final double pad = context.space.s4; // money-double: allow — геометрия UI (lp)
    final Widget left = SingleChildScrollView(
      key: landscapeAsideKey,
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(height: 56, child: _header(context, compact: true)),
          SizedBox(height: context.space.s2),
          if (size.height >= 480) _mascot(context, math.min(keyboardMascotSize, 96)),
          aside!,
          SizedBox(height: context.space.s4),
          _Footer(year: footerYear, padded: false),
        ],
      ),
    );
    final Widget right = Center(
      child: SingleChildScrollView(
        key: landscapeInputKey,
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: context.space.s2),
        child: input,
      ),
    );
    Widget split = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: left),
        Expanded(child: right),
      ],
    );
    if (card) {
      split = Center(
        child: Padding(
          padding: EdgeInsets.all(context.space.s6),
          child: Container(
            key: cardKey,
            constraints: const BoxConstraints(maxWidth: 2 * cardWidth),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.all(context.radii.xl),
              boxShadow: context.elevation.e2,
            ),
            clipBehavior: Clip.antiAlias,
            child: split,
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: backgroundOverride ?? (card ? c.background : c.surface),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            ...banners,
            Expanded(child: split),
          ],
        ),
      ),
    );
  }

  Widget _expanded(BuildContext context) {
    final DsColors c = context.colors;
    return Scaffold(
      backgroundColor: backgroundOverride ?? c.background,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _BrandPanel(mascot: mascot),
            Expanded(
              child: Column(
                children: <Widget>[
                  ...banners,
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(context.space.s6),
                        child: _card(
                          context,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              if (leading != null) ...<Widget>[
                                Align(alignment: Alignment.centerLeft, child: leading),
                                SizedBox(height: context.space.s4),
                              ],
                              body,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  _Footer(year: footerYear, withSupport: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.mascot});

  final MascotSlotBuilder? mascot;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final bool tall = MediaQuery.sizeOf(context).height >= 720;
    final List<(IconData, String, String)> features = <(IconData, String, String)>[
      (Icons.shopping_cart_outlined, l10n.auth_brand_feature_1_title, l10n.auth_brand_feature_1_body),
      (Icons.inventory_2_outlined, l10n.auth_brand_feature_2_title, l10n.auth_brand_feature_2_body),
      (Icons.description_outlined, l10n.auth_brand_feature_3_title, l10n.auth_brand_feature_3_body),
      (Icons.group_outlined, l10n.auth_brand_feature_4_title, l10n.auth_brand_feature_4_body),
    ];
    return Container(
      key: AuthLayout.brandPanelKey,
      width: AuthLayout.brandPanelWidth,
      color: c.surfaceVariant,
      padding: EdgeInsets.all(context.space.s7),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AuthLogo(wordmarkStyle: context.text.h3),
            SizedBox(height: context.space.s2),
            Text(l10n.auth_brand_subtitle, style: context.text.bodyLg.copyWith(color: c.textSecondary)),
            if (mascot != null) ...<Widget>[SizedBox(height: context.space.s7), Center(child: mascot!(context, 200))],
            if (tall) ...<Widget>[
              SizedBox(height: context.space.s6),
              Column(
                key: AuthLayout.featuresKey,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final (IconData icon, String title, String body) in features)
                    Padding(
                      padding: EdgeInsets.only(bottom: context.space.s4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(icon, size: 24, color: c.primaryText),
                          SizedBox(width: context.space.s3),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(title, style: context.text.label.copyWith(fontWeight: FontWeight.w600)),
                                Text(body, style: context.text.caption.copyWith(color: c.textSecondary)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            SizedBox(height: context.space.s6),
            Row(
              children: <Widget>[
                Icon(Icons.verified_user_outlined, size: 20, color: c.textSecondary),
                SizedBox(width: context.space.s2),
                Text(l10n.auth_brand_secure, style: context.text.caption.copyWith(color: c.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.year, this.padded = true, this.withSupport = false});

  final int year;
  final bool padded;
  final bool withSupport;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextStyle style = context.text.caption.copyWith(color: context.colors.textSecondary);
    final Widget copyright = Text(l10n.auth_footer_copyright('$year'), style: style, textAlign: TextAlign.center);
    return Padding(
      padding: padded ? EdgeInsets.all(context.space.s4) : EdgeInsets.zero,
      child: withSupport
          ? Row(
              children: <Widget>[
                Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: copyright),
                ),
                Flexible(
                  child: AppButton(
                    label: l10n.auth_support_title,
                    variant: AppButtonVariant.text,
                    size: AppButtonSize.s,
                    onPressed: () => showAuthSupport(context),
                  ),
                ),
              ],
            )
          : copyright,
    );
  }
}

/// Лист/диалог «Техническая поддержка» (UI-01-002). Контакты `supportContacts` из кэша
/// `GET /settings/public` появятся с RM-D-009; без кэша — `auth_support_fallback`.
Future<void> showAuthSupport(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return AppBottomSheet.show<void>(
    context,
    title: l10n.auth_support_title,
    body: Padding(
      padding: EdgeInsets.all(context.space.s4),
      child: Text(l10n.auth_support_fallback, style: context.text.body),
    ),
  );
}
