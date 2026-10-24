import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// `EnvBanner` `[НОВОЕ ИМЯ, 13 RM-C-008]` — постоянная полоса над приложением вне prod: явная маркировка
/// «тестовые данные» (фикстуры 1С, fake SMS) на dev и тестовом контуре (staging). В prod ([environmentCode] =
/// `null`) не рисуется и не занимает места.
///
/// Текст — технический маркер окружения латиницей (`DEV · TEST DATA`, `STAGING · TEST DATA`): ключа ARB для него
/// в 02 §7 нет (контракт l10n собирается из ТЗ, RM-B-007), маркер одинаков для всех языков — как код окружения.
class EnvBanner extends StatelessWidget {
  /// Создаёт баннер над [child].
  const EnvBanner({super.key, required this.environmentCode, required this.child});

  /// Ключ полосы (тесты, integration_test).
  static const Key bannerKey = Key('env-banner');

  /// Код окружения (`dev`, `staging`); `null` — prod, баннера нет.
  final String? environmentCode;

  /// Содержимое приложения.
  final Widget child;

  /// Текст маркера.
  static String labelFor(String environmentCode) => '${environmentCode.toUpperCase()} · TEST DATA';

  @override
  Widget build(BuildContext context) {
    final code = environmentCode;
    if (code == null) return child;
    final colors = context.colors;
    final label = labelFor(code);
    return Column(
      children: <Widget>[
        Semantics(
          key: bannerKey,
          container: true,
          label: label,
          excludeSemantics: true,
          child: ColoredBox(
            color: colors.warningContainer,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s1),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(Icons.science_outlined, size: 16, color: colors.textPrimary),
                      SizedBox(width: context.space.s2),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.caption.copyWith(color: colors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Верхний системный отступ уже занят полосой — содержимому он не нужен.
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
        ),
      ],
    );
  }
}
