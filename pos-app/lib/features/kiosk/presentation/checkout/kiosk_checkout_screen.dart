// SCR-52 «Планшет: оформление заявки» `/kiosk/checkout?step=phone|code` (02 ч. F SCR-52; 04 FLOW-044.S3–S6;
// P-002 §8.4 п. 4, §8.5; ADR-115; 13 TAB-2-04). Содержимое каркаса режима `KioskShellScreen` (маршрут корневого
// навигатора над SCR-51: drawer корзины остаётся под экраном, «Назад» с шага «Телефон» возвращает к нему).
//
// Раскладка (SCR-52.2): expanded / large — две колонки по центру (≤ 1040): слева состав и сумма UI-52-002 и текст
// информирования UI-52-003, справа шаг; medium — одна колонка ≤ 560: состав и сумма одной строкой → текст → шаг.
// Шапка UI-52-001 — «Назад» и заголовок шага (высота 64); под ней — один баннер UI-51-014: при `426` «Планшет нужно
// обновить» (`system_update`), иначе без связи — «Нет связи…» (`wifi_off`). Весь экран — в `SecureContent`
// (`FLAG_SECURE` на Android, UI-52-015; 10 KIOSK-021).
//
// Адрес — только шаг (`step`, заменой записи); номер, код, `challengeId` и ключ в адрес не попадают (02 ч. F,
// правило 3). Прямой путь и перезапуск (под экраном нет SCR-51) — `/kiosk`: номер и код не восстанавливаются
// (SCR-52.6). Без привязки портов ([KioskCheckoutState.bound]) экран пуст, как витрина без тела.
//
// Клавиатура (SCR-52.4): цифры и Backspace — `KioskKeypad`; Enter — активная основная кнопка; Esc и системное «Назад» —
// «Назад» (во время «Отправляем заявку…» — игнор).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/core/session/session_overlay.dart' show KioskStatus, kioskStatusProvider;
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_code_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_phone_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_sending_view.dart';

/// Пути режима планшета для переходов фичи (те же, что `KioskPaths` в `app/router/kiosk_routes.dart`; фича ↛ app —
/// литералы, совпадение проверяет тест экранов).
abstract final class KioskCheckoutLocations {
  /// SCR-51.
  static const String showcase = '/kiosk';

  /// SCR-52.
  static const String checkout = '/kiosk/checkout';

  /// SCR-53.
  static const String done = '/kiosk/done';

  /// Адрес шага SCR-52.
  static String step(KioskCheckoutStep step) => '$checkout?step=${step.value}';
}

/// SCR-52.
class KioskCheckoutScreen extends ConsumerStatefulWidget {
  const KioskCheckoutScreen({this.step = KioskCheckoutStep.phone, super.key});

  static const Key screenKey = ValueKey<String>('scr-52');
  static const Key backKey = ValueKey<String>('kiosk-checkout-back');
  static const Key titleKey = ValueKey<String>('kiosk-checkout-title');
  static const Key summaryKey = ValueKey<String>('kiosk-checkout-summary');
  static const Key offlineKey = ValueKey<String>('kiosk-checkout-offline');

  /// Баннер «Планшет нужно обновить» (`426`, UI-51-014) — вместо «Нет связи…».
  static const Key updateKey = ValueKey<String>('kiosk-checkout-update');

  /// Шаг из адреса (`step`). Шаг на экране выбирает контроллер: «Код» — только с кодом в памяти.
  final KioskCheckoutStep step;

  @override
  ConsumerState<KioskCheckoutScreen> createState() => _KioskCheckoutScreenState();
}

class _KioskCheckoutScreenState extends ConsumerState<KioskCheckoutScreen> {
  /// Шаг, записанный в адрес.
  late KioskCheckoutStep _addressStep = widget.step;

  KioskCheckoutController get _controller => ref.read(kioskCheckoutControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    if (!mounted) return;
    final KioskCheckoutState s = ref.read(kioskCheckoutControllerProvider);
    if (!s.bound) return;
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null && !router.canPop()) {
      // Под экраном нет SCR-51: прямой путь или перезапуск — номер и код не восстанавливаются (02 SCR-52.6).
      _controller.clear();
      router.go(KioskCheckoutLocations.showcase);
      return;
    }
    // Экран пересоздан поверх идущей отправки: итог придёт в состояние. Полноэкранные состояния и `426` память
    // оформления очищают (сброс FLOW-045 `blocked`, SCR-52 закрывается) — после них открытие начинается с «Телефон».
    if (s.publicNumber != null) {
      _toDone();
      return;
    }
    if (s.sending) return;
    final KioskCheckoutNav nav = await _controller.open();
    // Шаг мог остаться прежним (возврат по остатку — снова «Код»): адрес — по шагу на экране.
    if (mounted) _syncAddress(ref.read(kioskCheckoutControllerProvider).step);
    _apply(nav);
  }

  bool get _offline {
    final OnlineStatus s = ref.read(cartOnlineStatusProvider);
    return s == OnlineStatus.offline || s == OnlineStatus.serverDown;
  }

  /// Переход по итогу действия контроллера.
  void _apply(KioskCheckoutNav nav) {
    if (!mounted) return;
    switch (nav) {
      case KioskCheckoutNav.stay:
        return;
      case KioskCheckoutNav.showcase:
        _toShowcase();
      case KioskCheckoutNav.backToCart:
        // UI-51-018: строки корзины отмечены по ответу сервера (`warnings[]` `GET /cart` и строки `conflicts[]` отказа
        // заявки — отказанная строка отмечена всегда); над строками drawer — «Товара стало меньше…», пока корзина не
        // изменилась (отметку держит корзина).
        ref.read(kioskCartMarkStockChangedProvider)?.call(ref.read(kioskCheckoutControllerProvider).stockConflicts);
        _toShowcase();
      case KioskCheckoutNav.done:
        _toDone();
    }
  }

  /// Переход на SCR-53 выполнен.
  bool _done = false;

  /// SCR-53 вместо всего стека: страница `/kiosk` уходит вместе с drawer, в оформление не вернуться.
  void _toDone() {
    if (_done || !mounted) return;
    _done = true;
    GoRouter.maybeOf(context)?.go(KioskCheckoutLocations.done);
  }

  /// SCR-51: `pop` к drawer корзины; без SCR-51 под экраном — `/kiosk`.
  void _toShowcase() {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(KioskCheckoutLocations.showcase);
    }
  }

  /// «Назад»: с шага «Код» — шаг «Телефон»; с шага «Телефон» — SCR-51 с открытым drawer, память оформления очищена;
  /// во время отправки — игнор.
  void _back() {
    final KioskCheckoutState s = ref.read(kioskCheckoutControllerProvider);
    if (!s.bound || s.sending) return;
    if (s.step == KioskCheckoutStep.code) {
      _controller.changePhone();
      return;
    }
    _controller.clear();
    _toShowcase();
  }

  bool _canGetCode(KioskCheckoutState s) =>
      s.phoneComplete &&
      !s.busy &&
      !s.previewing &&
      !s.previewFailed &&
      s.preview != null &&
      !_offline &&
      !ref.read(cartOrderingBlockedProvider);

  bool _canSend(KioskCheckoutState s) =>
      s.codeComplete &&
      s.challengeId != null &&
      !s.codeLocked &&
      !s.busy &&
      !_offline &&
      !ref.read(cartOrderingBlockedProvider);

  bool _canResend(KioskCheckoutState s) =>
      s.phoneComplete && !s.busy && s.preview != null && !_offline && !ref.read(cartOrderingBlockedProvider);

  Future<void> _getCode() async {
    if (!_canGetCode(ref.read(kioskCheckoutControllerProvider))) return;
    _apply(await _controller.requestCode());
  }

  Future<void> _resend() async {
    if (!_canResend(ref.read(kioskCheckoutControllerProvider))) return;
    _apply(await _controller.requestCode());
  }

  Future<void> _send() async {
    if (!_canSend(ref.read(kioskCheckoutControllerProvider))) return;
    _apply(await _controller.submit());
  }

  /// Enter — активная основная кнопка шага.
  void _primary() {
    final KioskCheckoutState s = ref.read(kioskCheckoutControllerProvider);
    if (s.step == KioskCheckoutStep.phone) {
      unawaited(_getCode());
    } else {
      unawaited(_send());
    }
  }

  /// Адрес — шаг на экране (заменой записи, без перехода).
  void _syncAddress(KioskCheckoutStep step) {
    if (step == _addressStep) return;
    _addressStep = step;
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router != null) unawaited(router.replace<void>(KioskCheckoutLocations.step(step)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<KioskCheckoutStep>(
      kioskCheckoutControllerProvider.select((KioskCheckoutState s) => s.step),
      (KioskCheckoutStep? previous, KioskCheckoutStep next) => _syncAddress(next),
    );
    // Номер заявки пришёл (в том числе для отправки, начатой прежним экземпляром экрана) — SCR-53.
    ref.listen<String?>(kioskCheckoutControllerProvider.select((KioskCheckoutState s) => s.publicNumber), (
      String? previous,
      String? next,
    ) {
      if (next != null) _toDone();
    });
    // Связь вернулась после неудачного предпросмотра — новый предпросмотр без перезапуска шага.
    ref.listen<OnlineStatus>(cartOnlineStatusProvider, (OnlineStatus? previous, OnlineStatus next) {
      if (next == OnlineStatus.online && previous != OnlineStatus.online) {
        unawaited(_controller.retryPreview().then(_apply));
      }
    });
    final KioskCheckoutState s = ref.watch(kioskCheckoutControllerProvider);
    if (!s.bound) return const SizedBox.expand(key: KioskCheckoutScreen.screenKey);
    // Состояния, от которых зависят кнопки: сеть экрана и состояние планшета (`426`, полноэкранные, метка сброса).
    final OnlineStatus online = ref.watch(cartOnlineStatusProvider);
    ref.watch(cartOrderingBlockedProvider);
    final bool offline = online == OnlineStatus.offline || online == OnlineStatus.serverDown;
    final bool updateNeeded = ref.watch(kioskStatusProvider) == KioskStatus.updateNeeded;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final bool code = s.step == KioskCheckoutStep.code;
    final bool wide = switch (context.windowClass) {
      WindowClass.expanded || WindowClass.large => true,
      WindowClass.compact || WindowClass.medium => false,
    };

    final Widget header = Container(
      height: 64,
      padding: EdgeInsets.symmetric(horizontal: context.space.s4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: <Widget>[
          AppIconButton(
            key: KioskCheckoutScreen.backKey,
            icon: Icons.arrow_back_rounded,
            semanticLabel: code ? l10n.kiosk_change_phone : l10n.ds_button_close,
            onPressed: s.sending ? null : _back,
          ),
          SizedBox(width: context.space.s2),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                code ? l10n.kiosk_code_title : l10n.kiosk_phone_title,
                key: KioskCheckoutScreen.titleKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.h3.copyWith(color: c.textPrimary),
              ),
            ),
          ),
        ],
      ),
    );

    final Widget step = AnimatedSwitcher(
      // ANIM-024: смена шага — fade-through правой колонки 200 мс (reduce-motion — fade 80 мс).
      duration: context.motion.reduceMotion ? context.motion.reducedCrossfade : context.motion.base,
      child: KeyedSubtree(
        key: ValueKey<KioskCheckoutStep>(s.step),
        child: code ? _codeStep(s, l10n) : _phoneStep(s, l10n),
      ),
    );
    final Widget right = KioskSendingView(sending: s.sending, child: step);

    final Widget body;
    if (wide) {
      body = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(context.space.s6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _summary(s, l10n),
                      SizedBox(height: context.space.s6),
                      const KioskNoticeBlock(),
                    ],
                  ),
                ),
                SizedBox(width: context.space.s8),
                Expanded(child: right),
              ],
            ),
          ),
        ),
      );
    } else {
      body = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(context.space.s6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _summaryLine(s, l10n),
                SizedBox(height: context.space.s4),
                if (!code) ...<Widget>[const KioskNoticeBlock(), SizedBox(height: context.space.s4)],
                right,
              ],
            ),
          ),
        ),
      );
    }

    return SecureContent(
      child: PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (!didPop) _back();
        },
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): _back,
            const SingleActivator(LogicalKeyboardKey.enter): _primary,
            const SingleActivator(LogicalKeyboardKey.numpadEnter): _primary,
          },
          child: Focus(
            autofocus: true,
            child: ColoredBox(
              key: KioskCheckoutScreen.screenKey,
              color: c.background,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  header,
                  // UI-51-014: один баннер под шапкой — `426` важнее «Нет связи».
                  if (updateNeeded)
                    ErrorState.banner(
                      key: KioskCheckoutScreen.updateKey,
                      message: l10n.kiosk_update_needed,
                      tone: ErrorStateTone.warning,
                      icon: Icons.system_update_rounded,
                    )
                  else if (offline)
                    ErrorState.banner(
                      key: KioskCheckoutScreen.offlineKey,
                      message: l10n.kiosk_offline,
                      tone: ErrorStateTone.warning,
                      icon: Icons.wifi_off_rounded,
                    ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _phoneStep(KioskCheckoutState s, AppLocalizations l10n) => KioskPhoneStep(
    digits: s.phoneDigits,
    onDigit: _controller.typePhoneDigit,
    onBackspace: _controller.erasePhoneDigit,
    onCleared: _controller.clearPhone,
    onGetCode: _canGetCode(s) ? () => unawaited(_getCode()) : null,
    requesting: s.requestingCode,
    inputEnabled: !s.busy,
    message: switch (s.error) {
      KioskCheckoutError.callSeller => l10n.kiosk_call_seller,
      KioskCheckoutError.orderFailed => l10n.kiosk_order_failed,
      KioskCheckoutError.codeInvalid || KioskCheckoutError.codeExpired || null => null,
    },
  );

  Widget _codeStep(KioskCheckoutState s, AppLocalizations l10n) => KioskCodeStep(
    phoneE164: '+996${s.phoneDigits}',
    digits: s.codeDigits,
    resendAt: s.resendAt,
    now: ref.read(clockProvider).nowUtc,
    onDigit: _controller.typeCodeDigit,
    onBackspace: _controller.eraseCodeDigit,
    onSend: _canSend(s) ? () => unawaited(_send()) : null,
    onResend: _canResend(s) ? () => unawaited(_resend()) : null,
    onChangePhone: s.sending ? null : _controller.changePhone,
    // Нет действующего кода (`429` на номер без кода в памяти) — `kiosk_code_wait`, ввод недоступен (SCR-52.4).
    hasCode: s.challengeId != null,
    inputEnabled: !s.busy && s.challengeId != null,
    locked: s.codeLocked,
    sending: s.sending,
    resending: s.requestingCode,
    codeError: switch (s.error) {
      KioskCheckoutError.codeInvalid => l10n.kiosk_code_invalid(s.attemptsLeft ?? 0),
      KioskCheckoutError.codeExpired => l10n.kiosk_code_expired,
      KioskCheckoutError.callSeller || KioskCheckoutError.orderFailed || null => null,
    },
    message: switch (s.error) {
      KioskCheckoutError.callSeller => l10n.kiosk_call_seller,
      KioskCheckoutError.orderFailed => l10n.kiosk_order_failed,
      KioskCheckoutError.codeInvalid || KioskCheckoutError.codeExpired || null => null,
    },
  );

  /// UI-52-002 (expanded): «Товаров ({count})» и «Итого» по обычным ценам из предпросмотра; клиента, скидки и способа
  /// оплаты нет.
  Widget _summary(KioskCheckoutState s, AppLocalizations l10n) {
    final KioskPreview? p = s.preview;
    return CartSummary(
      key: KioskCheckoutScreen.summaryKey,
      rows: <CartSummaryRow>[CartSummaryRow(label: l10n.cart_summary_items(p?.positions ?? 0), amount: p?.subtotal)],
      totalLabel: l10n.cart_summary_total,
      total: p?.total,
      loading: p == null && s.previewing,
      large: true,
    );
  }

  /// UI-52-002 (medium): состав и сумма одной строкой.
  Widget _summaryLine(KioskCheckoutState s, AppLocalizations l10n) {
    final KioskPreview? p = s.preview;
    final DsColors c = context.colors;
    if (p == null) {
      return s.previewing
          ? const Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBox(width: 240, height: 24))
          : const SizedBox.shrink(key: KioskCheckoutScreen.summaryKey);
    }
    final String total = p.total == null ? '—' : PriceText.format(p.total!, fixed2: true);
    return Text(
      '${l10n.cart_summary_items(p.positions)} · ${l10n.cart_summary_total} $total',
      key: KioskCheckoutScreen.summaryKey,
      style: context.text.title.copyWith(
        color: c.textPrimary,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}
