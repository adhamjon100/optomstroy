import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Варианты `EmptyState` (03 §9.43). Тексты — ARB `ds_empty_<variant>_*` (передаёт экран).
enum EmptyStateVariant {
  search(Icons.search_off_rounded),
  category(Icons.inventory_2_outlined),
  cart(Icons.shopping_cart_outlined),
  favorites(Icons.star_outline_rounded),
  customers(Icons.person_search_outlined),
  transactions(Icons.swap_horiz_rounded),
  orders(Icons.receipt_outlined),
  parked(Icons.bookmark_outline_rounded),
  notifications(Icons.notifications_off_outlined),
  categories(Icons.category_outlined),
  offlineNoCache(Icons.cloud_off_rounded),
  noPermission(Icons.lock_outline_rounded),
  noCamera(Icons.no_photography_outlined);

  const EmptyStateVariant(this.icon);

  /// Глиф заглушки-иллюстрации (03 §7.7, §14.2).
  final IconData icon;
}

/// Пустое состояние `EmptyState` (03 §9.43): иллюстрация 120 (compact) / 160 → заголовок
/// `h3 textPrimary` → описание `body textSecondary` (≤ 2 строки) → `AppButton.primary M`
/// + [`AppButton.text M`]. Ширина текста ≤ 360. Появление — fade 200 мс (ANIM-022).
///
/// Иллюстрации раздела 14 ещё не утверждены: до их поступления рисуется заглушка —
/// глиф варианта на `primaryContainer` с акцентом `brandAccent` (≤ 20 % площади, п. 5.8).
class EmptyState extends StatelessWidget {
  /// Создаёт пустое состояние.
  const EmptyState({
    super.key,
    required this.variant,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
    this.illustration,
  });

  /// Вариант.
  final EmptyStateVariant variant;

  /// Заголовок.
  final String title;

  /// Описание (≤ 120 символов).
  final String? body;

  /// Основное действие («К каталогу»).
  final String? actionLabel;

  /// Основное действие.
  final VoidCallback? onAction;

  /// Второе действие.
  final String? secondaryActionLabel;

  /// Второе действие.
  final VoidCallback? onSecondaryAction;

  /// Иллюстрация раздела 14 (если есть ассет).
  final Widget? illustration;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool compact = context.windowClass == WindowClass.compact;
    final double size = compact ? 120 : 160;
    final Widget art = illustration ?? _Placeholder(icon: variant.icon, size: size);
    final List<Widget> actions = <Widget>[
      if (actionLabel != null) AppButton(label: actionLabel!, onPressed: onAction, expand: compact),
      if (secondaryActionLabel != null)
        AppButton(
          label: secondaryActionLabel!,
          onPressed: onSecondaryAction,
          variant: AppButtonVariant.text,
          expand: compact,
        ),
    ];
    final Widget content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExcludeSemantics(child: art),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.text.h3.copyWith(color: c.textPrimary),
            ),
            if (body != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(color: c.textSecondary),
              ),
            ],
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(height: 24),
              if (compact)
                Column(mainAxisSize: MainAxisSize.min, children: actions)
              else
                Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
    return _FadeIn(child: Center(child: content));
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: c.surfaceVariant, shape: BoxShape.circle),
          ),
          Container(
            width: size * 0.62,
            height: size * 0.62,
            decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
          ),
          Icon(icon, size: 48, color: c.textSecondary),
          // Оранжевый акцент — декоративный, не статус (03 §5.8, §14.1).
          Positioned(
            right: size * 0.16,
            top: size * 0.16,
            child: Container(
              width: size * 0.14,
              height: size * 0.14,
              decoration: BoxDecoration(color: c.brandAccent, shape: BoxShape.circle),
            ),
          ),
        ],
      ),
    );
  }
}

class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration d = context.motion.of(DsAnimations.emptyState.duration);
    if (d == Duration.zero) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: d,
      curve: DsAnimations.emptyState.curve,
      builder: (BuildContext context, double v, Widget? child) => Opacity(opacity: v, child: child),
      child: child,
    );
  }
}
