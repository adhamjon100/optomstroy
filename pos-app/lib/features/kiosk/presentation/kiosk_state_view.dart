// Состояния планшета магазина на экранах режима (02 SCR-51.7, UI-51-014, UI-51-015; AC-UI-51-009…AC-UI-51-013,
// AC-UI-90-020; navigation.md §4.3; P-002 §8.2 п. 6–8, §8.11 п. 3; ADR-115 п. 28; 13 TAB-2-10).
//
// Источник — `kioskStatusProvider` (core/session/session_overlay.dart). Маршрут не меняется:
// - полноэкранно (UI-51-015, без кнопок; витрины и корзины нет, шапка — только логотип с аварийным выходом):
//   «Планшет не в сети магазина» (`403 KIOSK_NETWORK_DENIED`), «Сервис временно недоступен» (`KIOSK_MODE=false`,
//   `403 KIOSK_DISABLED`, `kiosk_warehouse_unavailable`), «Планшет нужно подключить заново» (`401 SESSION_REVOKED`,
//   G-0a; закрепление остаётся), «Планшет отключён администратором» (`401 KIOSK_REVOKED`; [KioskStateView.revokedNotice],
//   затем SCR-01);
// - «Планшет нужно обновить» (`426`) — не полноэкранно: [child] остаётся, диалога SCR-90 C3 и ссылки на загрузку нет;
//   «В корзину» и «Оформить заявку» недоступны (`KioskStatus.blocksOrdering` — для тела витрины, TAB-2-03). Баннер
//   UI-51-014 рисуют сами SCR-51 и SCR-52 под своей шапкой (один баннер: `kiosk_update_needed` при `426`, иначе
//   «Нет связи» `kiosk_offline` по сети экрана); у SCR-53 баннера нет (UI-51-014 задан для SCR-51 и SCR-52).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/kiosk/presentation/emergency_exit_screen.dart';

/// Знак бренда (объявлен в pubspec) и wordmark — как у логотипа шапки каталога (ADR-114 П.1; не переводится).
const String _brandMarkAsset = 'assets/brand/logo_orange.png';
const String _brandWordmark = 'Оптомстрой';

/// Состояния планшета поверх содержимого экрана режима ([child] — витрина SCR-51 или шаг SCR-52/SCR-53).
class KioskStateView extends ConsumerStatefulWidget {
  const KioskStateView({required this.child, super.key});

  /// Сколько показывается «Планшет отключён администратором» до SCR-01 (02 SCR-51.7: 5 с [ТИПОВО]).
  static const Duration revokedNotice = Duration(seconds: 5);

  static const Key fullScreenKey = ValueKey<String>('kiosk-state-full-screen');
  static const Key logoKey = ValueKey<String>('kiosk-state-logo');

  final Widget child;

  @override
  ConsumerState<KioskStateView> createState() => _KioskStateViewState();
}

class _KioskStateViewState extends ConsumerState<KioskStateView> {
  Timer? _revokedTimer;

  @override
  void dispose() {
    _revokedTimer?.cancel();
    super.dispose();
  }

  /// «Планшет отключён администратором» на экране [KioskStateView.revokedNotice], затем SCR-01; ушли из состояния
  /// раньше (аварийный выход поверх отзыва) — отсчёт снимается.
  void _syncRevokedNotice(KioskStatus status) {
    if (status != KioskStatus.revoked) {
      _revokedTimer?.cancel();
      _revokedTimer = null;
      return;
    }
    _revokedTimer ??= Timer(KioskStateView.revokedNotice, () {
      _revokedTimer = null;
      if (mounted) ref.read(sessionControllerProvider.notifier).acknowledgeKioskRevoked();
    });
  }

  @override
  Widget build(BuildContext context) {
    final KioskStatus status = ref.watch(kioskStatusProvider);
    _syncRevokedNotice(status);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Widget body;
    if (status.isFullScreen) {
      body = Column(
        key: KioskStateView.fullScreenKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const KioskLogoHeader(),
          Expanded(
            child: _KioskFullScreenState(status: status, l10n: l10n),
          ),
        ],
      );
    } else {
      // `426` — баннер под шапкой экрана (SCR-51 `KioskCatalogKeys.updateBanner`, SCR-52 `KioskCheckoutScreen.updateKey`).
      body = widget.child;
    }
    // ANIM-024: витрина ↔ полноэкранное состояние — fade 200 мс (reduce-motion — без анимации).
    return AnimatedSwitcher(
      duration: context.motion.of(context.motion.base),
      child: KeyedSubtree(key: ValueKey<bool>(status.isFullScreen), child: body),
    );
  }
}

/// Шапка полноэкранного состояния и SCR-53 — только логотип; долгое нажатие 5 с — аварийный выход (UI-51-002,
/// UI-51-017; 02 SCR-53.2).
class KioskLogoHeader extends StatelessWidget {
  const KioskLogoHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1; // money-double: allow — геометрия UI (lp)
    return Container(
      height: 69,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      alignment: AlignmentDirectional.centerStart,
      child: KioskEmergencyExitTrigger(
        child: Semantics(
          key: KioskStateView.logoKey,
          label: AppLocalizations.of(context).splash_logo_a11y,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Image.asset(
                _brandMarkAsset,
                width: 38,
                height: 38,
                cacheWidth: (38 * dpr).ceil(),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
                    const SizedBox.square(dimension: 38),
              ),
              const SizedBox(width: 10),
              Text(_brandWordmark, maxLines: 1, style: context.text.brandWordmark.copyWith(color: c.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// UI-51-015: иллюстрация тона, текст состояния; кнопок нет (в отличие от UI-50-015 — без «Выйти» и «Связаться»).
class _KioskFullScreenState extends StatelessWidget {
  const _KioskFullScreenState({required this.status, required this.l10n});

  final KioskStatus status;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final (String message, ErrorStateTone tone) = switch (status) {
      KioskStatus.networkDenied => (l10n.kiosk_network_denied, ErrorStateTone.warning),
      KioskStatus.unavailable => (l10n.kiosk_unavailable, ErrorStateTone.info),
      KioskStatus.reconnectNeeded => (l10n.kiosk_reconnect_needed, ErrorStateTone.warning),
      KioskStatus.revoked => (l10n.kiosk_revoked, ErrorStateTone.warning),
      KioskStatus.none || KioskStatus.ready || KioskStatus.updateNeeded => ('', ErrorStateTone.info),
    };
    final (Color bg, Color fg, IconData icon) = ErrorState.toneOf(c, tone);
    // Указание владельца 2026-11-18 (15 §5.8 (3); 02 UI-51-015): в низком окне (ландшафт, масштаб текста 1,3)
    // иллюстрация и текст прокручиваются, а не выходят за край (прежде — на 13 lp).
    return ColoredBox(
      color: c.background,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight, minWidth: box.maxWidth),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Semantics(
                    liveRegion: true,
                    container: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        ExcludeSemantics(
                          child: Container(
                            width: 160,
                            height: 160,
                            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                            child: Icon(icon, size: 56, color: fg),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: context.text.h3.copyWith(color: c.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
