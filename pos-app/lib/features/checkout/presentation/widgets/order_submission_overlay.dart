// UI-20-020 «Проверяем результат создания заказа…» (02 SCR-20.3, SCR-20.11, SCR-20.11.1; AC-UI-20-019, AC-UI-20-028)
// и переходы по итогам ожидания ([OrderSubmissionHost]). Оверлей корень подставляет в `CartPanel` (порт фичи cart
// `cartSubmissionOverlayProvider`), хост — в оболочку приложения: переход в SCR-22 выполняется, даже если корзина
// сейчас не на экране (compact/medium).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/checkout/presentation/checkout_formats.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';

/// Ключи (тесты).
abstract final class OrderSubmissionKeys {
  static const Key overlay = ValueKey<String>('order-submission-overlay');
  static const Key retry = ValueKey<String>('order-submission-retry');
  static const Key openOrders = ValueKey<String>('order-submission-open-orders');
  static const Key unlock = ValueKey<String>('order-submission-unlock');
}

/// SCR-25 «Мои» за сегодня (02 SCR-20.11.1 этап 3: фильтр «Мои», период «Сегодня»).
String ordersTodayMineLocation(DateTime nowUtc) {
  final DateTime b = CheckoutFormats.bishkek(nowUtc);
  final DateTime from = DateTime.utc(b.year, b.month, b.day).subtract(CheckoutFormats.bishkekOffset);
  final DateTime to = from.add(const Duration(days: 1));
  return Uri(
    path: '/orders',
    queryParameters: <String, String>{'mine': '1', 'from': from.toIso8601String(), 'to': to.toIso8601String()},
  ).toString();
}

/// Оверлей блокировки корзины поверх зон D–G (фон `surface` 0,9).
class OrderSubmissionOverlay extends ConsumerWidget {
  const OrderSubmissionOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final OrderSubmissionState s = ref.watch(orderSubmissionRecoveryProvider);
    final OrderSubmissionRecovery ctl = ref.read(orderSubmissionRecoveryProvider.notifier);
    final bool finalState = s.phase == OrderSubmissionPhase.checkList || s.phase == OrderSubmissionPhase.expired;
    return ColoredBox(
      key: OrderSubmissionKeys.overlay,
      color: c.surface.withValues(alpha: 0.9),
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(context.space.s5),
          child: Semantics(
            liveRegion: true,
            container: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (!finalState || s.inFlight) ...<Widget>[
                  const AppProgress.circular(size: 32),
                  SizedBox(height: context.space.s3),
                ],
                Text(
                  finalState ? l10n.cart_result_unknown_check_list : l10n.cart_result_unknown_title,
                  textAlign: TextAlign.center,
                  style: context.text.body.copyWith(color: c.textPrimary),
                ),
                if (s.long && !finalState) ...<Widget>[
                  SizedBox(height: context.space.s2),
                  Text(
                    l10n.cart_result_unknown_long,
                    textAlign: TextAlign.center,
                    style: context.text.caption.copyWith(color: c.textSecondary),
                  ),
                ],
                if (s.canRetryNow || finalState) SizedBox(height: context.space.s4),
                if (finalState)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.space.s2),
                    child: AppButton(
                      key: OrderSubmissionKeys.openOrders,
                      label: l10n.cart_result_unknown_open_orders,
                      variant: AppButtonVariant.outlined,
                      expand: true,
                      onPressed: () =>
                          GoRouter.of(context).go(ordersTodayMineLocation(ref.read(clockProvider).nowUtc())),
                    ),
                  ),
                if (s.phase == OrderSubmissionPhase.expired)
                  AppButton(
                    key: OrderSubmissionKeys.unlock,
                    label: l10n.cart_result_unknown_unlock,
                    variant: AppButtonVariant.tonal,
                    expand: true,
                    onPressed: () => unawaited(ctl.unlockExpired()),
                  )
                else if (s.canRetryNow || (finalState && s.inFlight))
                  AppButton(
                    key: OrderSubmissionKeys.retry,
                    label: l10n.cart_result_unknown_retry,
                    variant: AppButtonVariant.tonal,
                    expand: true,
                    loading: s.inFlight,
                    onPressed: s.inFlight ? null : () => unawaited(ctl.retryNow()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Хост оболочки: создаёт провайдер ожидания (после перезапуска — поиск заказа по ключу) и выполняет переходы:
/// заказ создан/найден → SCR-22; после перезапуска заказ не найден → SCR-21 с сохранёнными шагами; окончательный
/// отказ → снекбар «Не удалось…» (корзина сверена).
class OrderSubmissionHost extends ConsumerWidget {
  const OrderSubmissionHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<OrderSubmissionState>(orderSubmissionRecoveryProvider, (
      OrderSubmissionState? _,
      OrderSubmissionState s,
    ) {
      if (s.created == null && !s.reopenCheckout && s.rejected == null) return;
      // Переход — после кадра: слушатель вызывается при смене состояния провайдера.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final OrderSubmissionRecovery ctl = ref.read(orderSubmissionRecoveryProvider.notifier);
        final CheckoutCreated? created = ctl.takeCreated();
        if (created != null) {
          ref
              .read(checkoutNavigatorProvider)
              .orderCreated(context, orderId: created.orderId, paymentId: created.paymentId);
          return;
        }
        if (ctl.takeReopenCheckout()) {
          unawaited(GoRouter.of(context).push<void>('/checkout'));
          return;
        }
        final Failure? rejected = ctl.takeRejected();
        if (rejected != null) {
          final AppLocalizations l10n = AppLocalizations.of(context);
          AppSnackbar.show(
            context,
            message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(rejected)),
            variant: AppSnackbarVariant.error,
          );
        }
      });
    });
    return child;
  }
}
