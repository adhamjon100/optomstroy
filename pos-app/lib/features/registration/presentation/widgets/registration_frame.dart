// Каркас экранов регистрации (02 Часть A §0.1): compact — `surface` на весь экран с полями 16;
// medium/expanded — фон `background` и карточка 560 (радиус `xl` 20 для SCR-03/04, `lg` 16 для SCR-06/07),
// внутренний отступ 24, тень `elevation.2`. Вне AdaptiveScaffold (без навигации приложения).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

class RegistrationFrame extends StatelessWidget {
  const RegistrationFrame({
    super.key,
    required this.child,
    this.header,
    this.bottom,
    this.largeRadius = true,
    this.screenKey,
  });

  /// Прокручиваемое содержимое.
  final Widget child;

  /// Шапка (назад / заголовок «Регистрация»).
  final Widget? header;

  /// Закреплённая внизу кнопка (compact) / низ карточки.
  final Widget? bottom;

  /// `true` — радиус `xl` (SCR-03/04), иначе `lg` (SCR-06/07).
  final bool largeRadius;

  final Key? screenKey;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final compact = context.windowClass == WindowClass.compact;
    final content = Column(
      mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ?header,
        if (compact)
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s4, context.space.s4, context.space.s4),
              child: child,
            ),
          )
        else
          Flexible(
            child: SingleChildScrollView(padding: EdgeInsets.all(context.space.s6), child: child),
          ),
        if (bottom != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? context.space.s4 : context.space.s6,
              0,
              compact ? context.space.s4 : context.space.s6,
              compact ? context.space.s4 : context.space.s6,
            ),
            child: bottom,
          ),
      ],
    );
    return Scaffold(
      key: screenKey,
      backgroundColor: compact ? c.surface : c.background,
      body: SafeArea(
        child: compact
            ? content
            : Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: context.space.s8, bottom: context.space.s6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Material(
                      color: c.surface,
                      elevation: 2,
                      shadowColor: c.overlay,
                      borderRadius: BorderRadius.all(largeRadius ? context.radii.xl : context.radii.lg),
                      clipBehavior: Clip.antiAlias,
                      child: content,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Шапка экранов регистрации: «←» / «Отменить регистрацию», заголовок по центру (compact).
class RegistrationHeader extends StatelessWidget {
  const RegistrationHeader({super.key, required this.title, this.onBack, this.backLabel, this.backKey});

  final String title;
  final VoidCallback? onBack;
  final String? backLabel;
  final Key? backKey;

  @override
  Widget build(BuildContext context) {
    final compact = context.windowClass == WindowClass.compact;
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          if (onBack != null)
            compact
                ? IconButton(
                    key: backKey,
                    tooltip: backLabel,
                    onPressed: onBack,
                    icon: Icon(Icons.arrow_back_rounded, color: context.colors.textSecondary),
                  )
                : Padding(
                    padding: EdgeInsets.only(left: context.space.s4),
                    child: TextButton.icon(
                      key: backKey,
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_rounded, size: 20),
                      label: Text(backLabel ?? title),
                    ),
                  )
          else
            const SizedBox(width: 48),
          Expanded(
            child: Text(
              compact ? title : '',
              textAlign: TextAlign.center,
              style: context.text.title.copyWith(color: context.colors.textPrimary),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

/// ANIM-020 (`AnimatedSize` + 200 мс); при reduce-motion — мгновенно (AnimatedSize с нулевой длительностью
/// перестраивает раскладку во время layout).
class RevealSize extends StatelessWidget {
  const RevealSize({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = context.motion.of(context.motion.fast);
    return d == Duration.zero ? child : AnimatedSize(duration: d, alignment: Alignment.topCenter, child: child);
  }
}
