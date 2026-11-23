// SCR-53 «Планшет: заявка отправлена» `/kiosk/done` (02 ч. F SCR-53; 04 FLOW-044.S7, FLOW-045.S5; 10 KIOSK-016;
// 11 SEC-141, PRIV-033; Р-09 (а); 13 TAB-2-04). Содержимое каркаса режима `KioskShellScreen`.
//
// Крупно — номер заявки из ответа `POST /kiosk/orders` (только память контроллера оформления: в адрес, drift,
// защищённое хранилище и журналы не пишется), «Подойдите к кассе…», «Договорные цены применит кассир», «Готово» и
// полоса оставшегося времени `kiosk_done_seconds` (по умолчанию 60 с, `GET /settings/public` → `kiosk.doneSeconds`).
// Сумм, статуса и клиента нет. Касания таймер не продлевают [ТИПОВО]. «Готово», конец таймера и системное «Назад» —
// сброс FLOW-045 (порт `catalogKioskStartOverProvider`, оркестратор — 13 TAB-2-05; без привязки — перечитать корзину)
// и SCR-51 стартовой категории; повторное нажатие во время сброса игнорируется. Без номера (перезапуск, прямой путь) —
// `/kiosk`. Шапка — только логотип с аварийным выходом (UI-51-002, UI-51-017).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/keep_words_text.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_motion.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_state_view.dart';

/// SCR-53.
class KioskDoneScreen extends ConsumerStatefulWidget {
  const KioskDoneScreen({super.key});

  static const Key screenKey = ValueKey<String>('scr-53');
  static const Key numberKey = ValueKey<String>('kiosk-done-number');
  static const Key doneKey = ValueKey<String>('kiosk-done');
  static const Key progressKey = ValueKey<String>('kiosk-done-progress');

  @override
  ConsumerState<KioskDoneScreen> createState() => _KioskDoneScreenState();
}

class _KioskDoneScreenState extends ConsumerState<KioskDoneScreen> with TickerProviderStateMixin {
  /// Номер — снимок при открытии: очистка памяти оформления при сбросе его не убирает с экрана до перехода.
  String? _number;
  bool _bound = false;
  Duration _total = KioskTimings.defaultDone;

  /// Полоса оставшегося времени: 1 → 0 за [_total].
  late final AnimationController _progress;

  /// Иконка успеха (SCR-53.5): scale 0.8 → 1 + fade, 200 мс `emphasized`.
  late final AnimationController _icon;
  late final CurvedAnimation _iconCurve;

  /// Масштаб иконки 0.8 → 1 (геометрия, не деньги).
  late final Animation<double> _iconScale; // money-double: allow — масштаб иконки

  static final Tween<double> _iconTween = Tween<double>(begin: 0.8, end: 1); // money-double: allow — масштаб иконки

  /// С открытия экрана (полоса времени в reduce-motion).
  final Stopwatch _elapsed = Stopwatch();
  Timer? _end;
  Timer? _tick;
  bool _started = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, value: 1);
    _icon = AnimationController(vsync: this, duration: DsMotion.defaults.base);
    _iconCurve = CurvedAnimation(parent: _icon, curve: DsMotion.defaults.emphasized);
    _iconScale = _iconCurve.drive(_iconTween);
    final KioskCheckoutState s = ref.read(kioskCheckoutControllerProvider);
    _number = s.publicNumber;
    _bound = s.bound;
    if (_number == null) {
      // Без номера (перезапуск, прямой путь) — SCR-51 (02 SCR-53.7 «Пусто»).
      if (_bound) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) GoRouter.maybeOf(context)?.go(KioskCheckoutLocations.showcase);
        });
      }
      return;
    }
    _total = ref.read(kioskTimingsProvider).done;
    _end = Timer(_total, () => unawaited(_finish()));
    _elapsed.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || _number == null) return;
    _started = true;
    if (context.motion.reduceMotion) {
      // Reduce-motion: иконка без scale, полоса без анимации, обновление раз в секунду.
      _icon.value = 1;
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final int left = _total.inMilliseconds - _elapsed.elapsedMilliseconds;
        _progress.value = left <= 0 ? 0 : left / _total.inMilliseconds;
      });
    } else {
      unawaited(_icon.forward());
      _progress.duration = _total;
      unawaited(_progress.reverse(from: 1));
    }
  }

  @override
  void dispose() {
    _end?.cancel();
    _tick?.cancel();
    _iconCurve.dispose();
    _icon.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// «Готово», конец таймера, «Назад»: сброс FLOW-045 и SCR-51 стартовой категории (один раз).
  Future<void> _finish() async {
    if (_finishing || !mounted) return;
    setState(() => _finishing = true);
    _end?.cancel();
    _tick?.cancel();
    _progress.stop();
    final Future<void> Function()? startOver = ref.read(catalog.catalogKioskStartOverProvider);
    try {
      if (startOver != null) {
        await startOver();
      } else {
        // Без оркестратора сброса — хотя бы новая корзина вместо оформленной (`GET /cart`).
        await ref.read(kioskCheckoutCartProvider)?.refresh();
      }
    } on Object {
      // Ошибка сброса покупателю не показывается (02 SCR-53.7): сброс без сети — по метке (FLOW-045.A1).
    }
    if (!mounted) return;
    ref.read(kioskCheckoutControllerProvider.notifier).clear();
    GoRouter.maybeOf(context)?.go(KioskCheckoutLocations.showcase);
  }

  @override
  Widget build(BuildContext context) {
    final String? number = _number;
    if (number == null) return const SizedBox.expand(key: KioskDoneScreen.screenKey);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return PopScope<Object?>(
      canPop: false,
      // Системное «Назад» = «Готово»: в оформление вернуться нельзя (AC-UI-53-004).
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) unawaited(_finish());
      },
      child: ColoredBox(
        key: KioskDoneScreen.screenKey,
        color: c.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const KioskLogoHeader(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(context.space.s6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        ExcludeSemantics(
                          child: FadeTransition(
                            opacity: _iconCurve,
                            child: ScaleTransition(
                              scale: _iconScale,
                              child: Icon(Icons.check_circle_rounded, size: 64, color: c.success),
                            ),
                          ),
                        ),
                        SizedBox(height: context.space.s6),
                        Semantics(
                          liveRegion: true,
                          // Без предела строк: при масштабе текста 1.3× заголовок переносится целиком (02 UI-53-002,
                          // AC-UI-53-008; 03 A11Y-005) — экран прокручивается. Номер заявки не разрывается внутри: не
                          // помещается в строку — начертание на ступень меньше (T-UI-117, пакет own-server:GAP-APP).
                          child: DsKeepWordsText(
                            l10n.kiosk_order_sent_title(number),
                            textKey: KioskDoneScreen.numberKey,
                            textAlign: TextAlign.center,
                            style: context.text.display.copyWith(
                              color: c.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontFeatures: DsTypography.numeric,
                            ),
                            fallback: <TextStyle>[
                              for (final TextStyle s in <TextStyle>[context.text.h1, context.text.h2, context.text.h3])
                                s.copyWith(
                                  color: c.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: DsTypography.numeric,
                                ),
                            ],
                          ),
                        ),
                        SizedBox(height: context.space.s4),
                        Text(
                          l10n.kiosk_order_sent_body,
                          textAlign: TextAlign.center,
                          style: context.text.bodyLg.copyWith(color: c.textPrimary),
                        ),
                        SizedBox(height: context.space.s2),
                        Text(
                          l10n.kiosk_price_note,
                          textAlign: TextAlign.center,
                          style: context.text.body.copyWith(color: c.textSecondary),
                        ),
                        SizedBox(height: context.space.s8),
                        SizedBox(
                          width: 320,
                          child: AppButton(
                            key: KioskDoneScreen.doneKey,
                            label: l10n.kiosk_done,
                            size: AppButtonSize.l,
                            expand: true,
                            autofocus: true,
                            loading: _finishing,
                            onPressed: _finishing ? null : () => unawaited(_finish()),
                          ),
                        ),
                        SizedBox(height: context.space.s6),
                        SizedBox(
                          width: 320,
                          child: ExcludeSemantics(
                            child: AnimatedBuilder(
                              animation: _progress,
                              builder: (BuildContext context, Widget? _) =>
                                  AppProgress.linear(key: KioskDoneScreen.progressKey, value: _progress.value),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
