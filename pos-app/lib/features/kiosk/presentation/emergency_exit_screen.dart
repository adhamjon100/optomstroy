// Аварийный выход из режима «Планшет магазина» — SCR-51 UI-51-017 (02 SCR-51.4 «UI-51-017 аварийный выход» пп. 1–4,
// AC-UI-51-016, AC-UI-51-017; P-002 §8.9 п. 2; 04 FLOW-043.A1; 08 §4.25.5; 09 §8.9 п. 4–5; 11 SEC-140; ADR-115 п. 12,
// п. 28; 13 TAB-2-10).
//
// Открывается долгим нажатием 5 с на логотип ([KioskEmergencyExitTrigger]) в любом состоянии экрана планшета;
// подсказки о долгом нажатии нет. Код — 8 цифр, только экранными кнопками; поля системной клавиатуры нет, поэтому
// код не попадает ни в подсказки клавиатуры, ни в буфер обмена. Порядок проверки ([KioskEmergencyExit]):
//   1. есть сессия планшета — `POST /kiosk/exit` (сервер): `200` — выход; `422` — «Неверный код. Осталось попыток: {n}»;
//      `423` — «Слишком много попыток…», кнопки недоступны до конца паузы; после отказа сервера код на устройстве
//      НЕ проверяется;
//   2. сервер код не проверил (нет сети, таймаут, `426`, `401 SESSION_REVOKED`, `403 KIOSK_DISABLED`,
//      `403 KIOSK_NETWORK_DENIED` и т. п.) или сессии нет («Подключите заново») — проверка по хэшу на устройстве:
//      счётчик и пауза 15 мин переживают перезапуск; после выхода SCR-01 показывает `kiosk_exit_offline_hint`.
// Любой выход: токены, признак и хэш удаляются, закрепление снимается (`SessionController.endKiosk`), затем SCR-01.
// Повторное нажатие во время проверки игнорируется. Код не логируется.
//
// Клавиатура — экранная `KioskKeypad` дизайн-системы (03 §9.74, вариант 8 цифр, TAB-2-04; клавиши 88 × 64, A11Y-023);
// физическая клавиатура вводит цифры и Backspace туда же. Поле кода — только для отображения (8 позиций, цифры
// скрыты): поля ввода (`EditableText`) у кода нет, поэтому он не попадает ни в IME, ни в автозаполнение браузера.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/kiosk_exit_code_hash.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';

/// Итог попытки аварийного выхода.
sealed class KioskExitOutcome {
  const KioskExitOutcome();
}

/// Выход выполнен ([offline] — код проверен на устройстве): режим планшета закончен, дальше SCR-01.
final class KioskExitDone extends KioskExitOutcome {
  const KioskExitDone({required this.offline});

  final bool offline;

  @override
  String toString() => 'KioskExitDone(offline: $offline)';
}

/// Неверный код: [attemptsLeft] — сколько неверных ещё до паузы; `null` — сервер число не сообщил («Неверный
/// аварийный код» без числа попыток).
final class KioskExitRejected extends KioskExitOutcome {
  const KioskExitRejected(this.attemptsLeft);

  final int? attemptsLeft;

  @override
  String toString() => 'KioskExitRejected($attemptsLeft)';
}

/// Проверка не выполнена: сбой хранилища или вычисления хэша. Код мог быть верным, счётчик не менялся — «Не удалось
/// выполнить. Повторите», без числа попыток (02 UI-51-017 п. 2–3: «Неверный код…» — только по ответу сервера или
/// проверке на устройстве).
final class KioskExitFailed extends KioskExitOutcome {
  const KioskExitFailed();

  @override
  String toString() => 'KioskExitFailed';
}

/// Пауза после 5 неверных: ввод недоступен до [until] (UTC).
final class KioskExitPaused extends KioskExitOutcome {
  const KioskExitPaused(this.until);

  final DateTime until;

  @override
  String toString() => 'KioskExitPaused(${until.toIso8601String()})';
}

/// Проверка аварийного кода: сначала сервер, без проверки сервером — устройство.
final class KioskEmergencyExit {
  KioskEmergencyExit(this._ref);

  final Ref _ref;

  /// Длина кода (08 §4.25.5).
  static const int codeLength = 8;

  /// Пауза по умолчанию, если сервер не сообщил `retryAfter` (5 неверных — 15 мин, SEC-140 п. 3).
  static const Duration defaultPause = KioskExitCodeStore.lockDuration;

  /// Действующая пауза проверки на устройстве (при открытии диалога).
  Future<DateTime?> pausedUntil() => _ref.read(kioskExitCodeStoreProvider).lockedUntil();

  /// Проверить [code] и при успехе завершить режим планшета.
  Future<KioskExitOutcome> submit(String code) async {
    final SessionState session = _ref.read(sessionControllerProvider);
    final KioskLifecycleRepository? server = _ref.read(kioskLifecycleRepositoryProvider);
    if (session.isKioskSession && server != null) {
      switch (await server.exit(code)) {
        case KioskServerExitAccepted():
          await _ref.read(sessionControllerProvider.notifier).endKiosk(SessionEndReason.kioskExited);
          return const KioskExitDone(offline: false);
        case KioskServerExitInvalid(:final int? attemptsLeft):
          return KioskExitRejected(attemptsLeft);
        case KioskServerExitLocked(:final Duration? retryAfter):
          return KioskExitPaused(_ref.read(clockProvider).nowUtc().add(retryAfter ?? defaultPause));
        case KioskServerExitNotChecked():
          break;
      }
    }
    switch (await _ref.read(kioskExitCodeStoreProvider).verify(code)) {
      case KioskDeviceExitAccepted():
        await _ref.read(sessionControllerProvider.notifier).endKiosk(SessionEndReason.kioskExitedOffline);
        return const KioskExitDone(offline: true);
      case KioskDeviceExitInvalid(:final int attemptsLeft):
        return KioskExitRejected(attemptsLeft);
      case KioskDeviceExitLocked(:final DateTime until):
        return KioskExitPaused(until);
    }
  }
}

/// Проверка аварийного кода (тесты подменяют сервер, хранилище и сессию).
final kioskEmergencyExitProvider = Provider<KioskEmergencyExit>(KioskEmergencyExit.new);

/// Долгое нажатие 5 с на [child] (логотип) открывает аварийный выход (UI-51-002, UI-51-017). Жест служебный и в
/// дерево доступности не выводится (подсказки о долгом нажатии нет — UI-51-002): логотип для диктора — просто текст,
/// без действия и без тач-цели 48 (AC-A11Y-023 `androidTapTargetGuideline`).
class KioskEmergencyExitTrigger extends StatelessWidget {
  const KioskEmergencyExitTrigger({required this.child, super.key});

  /// Удержание до открытия диалога (P-002 §8.9 п. 2).
  static const Duration holdDuration = Duration(seconds: 5);

  final Widget child;

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    gestures: <Type, GestureRecognizerFactory>{
      LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
        () => LongPressGestureRecognizer(duration: holdDuration, debugOwner: this),
        (LongPressGestureRecognizer recognizer) =>
            recognizer.onLongPress = () => unawaited(showKioskEmergencyExit(context)),
      ),
    },
    child: child,
  );
}

final ValueNotifier<bool> _exitDialogOpen = ValueNotifier<bool>(false);

/// Имя маршрута диалога аварийного выхода: сброс FLOW-045 при входе в состояние, где покупка невозможна
/// (`KioskResetReason.blocked`), его не закрывает — администратор может вводить код (02 SCR-51.7, T-KIOSK-033).
const String kioskEmergencyExitRouteName = 'kiosk-emergency-exit';

/// Диалог аварийного выхода на экране: таймер бездействия автосброса в это время не идёт (02 SCR-51.4; TAB-2-05).
ValueListenable<bool> get kioskEmergencyExitShown => _exitDialogOpen;

/// Показать диалог аварийного выхода (повторное открытие, пока он на экране, игнорируется).
Future<void> showKioskEmergencyExit(BuildContext context) async {
  if (_exitDialogOpen.value) return;
  _exitDialogOpen.value = true;
  try {
    final DsColors c = context.colors;
    final Duration d = context.motion.of(DsAnimations.dialog.duration);
    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      routeSettings: const RouteSettings(name: kioskEmergencyExitRouteName),
      barrierDismissible: false,
      barrierLabel: AppLocalizations.of(context).ds_button_cancel,
      barrierColor: c.overlay,
      transitionDuration: d,
      pageBuilder:
          (
            BuildContext ctx,
            Animation<double> a, // money-double: allow — анимация перехода, не деньги
            Animation<double> b, // money-double: allow — анимация перехода, не деньги
          ) => const KioskEmergencyExitDialog(),
      transitionBuilder:
          (
            BuildContext ctx,
            Animation<double> a, // money-double: allow — анимация перехода, не деньги
            Animation<double> b, // money-double: allow — анимация перехода, не деньги
            Widget child,
          ) {
            final CurvedAnimation curve = CurvedAnimation(parent: a, curve: DsAnimations.dialog.curve);
            return FadeTransition(
              opacity: curve,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(curve), // money-double: allow — масштаб диалога
                child: child,
              ),
            );
          },
    );
  } finally {
    _exitDialogOpen.value = false;
  }
}

/// Диалог UI-51-017: заголовок, поле кода (8 позиций, цифры скрыты), экранные кнопки, «Выйти из режима планшета» и
/// «Отмена».
class KioskEmergencyExitDialog extends ConsumerStatefulWidget {
  const KioskEmergencyExitDialog({super.key});

  static const Key dialogKey = ValueKey<String>('kiosk-exit-dialog');
  static const Key submitKey = ValueKey<String>('kiosk-exit-submit');
  static const Key cancelKey = ValueKey<String>('kiosk-exit-cancel');
  static const Key errorKey = ValueKey<String>('kiosk-exit-error');

  /// Ключ экранной кнопки цифры [digit] (`'0'…'9'`) и стирания (`'backspace'`) — клавиши [KioskKeypad].
  static Key keyFor(String digit) => KioskKeypad.keyFor(digit);

  @override
  ConsumerState<KioskEmergencyExitDialog> createState() => _KioskEmergencyExitDialogState();
}

class _KioskEmergencyExitDialogState extends ConsumerState<KioskEmergencyExitDialog> {
  final FocusNode _focus = FocusNode(debugLabel: 'KioskEmergencyExitDialog');

  /// Набранный код — только в памяти диалога.
  String _code = '';
  bool _busy = false;
  KioskExitOutcome? _failure;
  DateTime? _pausedUntil;
  Timer? _pauseTimer;

  /// Пересчёт «Повторите через {minutes} мин», пока идёт пауза (текст убывает, а не стоит на 15 мин).
  Timer? _tick;
  int _shake = 0;

  bool get _paused => _pausedUntil != null;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPause());
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _tick?.cancel();
    _tick = null;
    _focus.dispose();
    _code = '';
    super.dispose();
  }

  Future<void> _loadPause() async {
    final DateTime? found;
    try {
      found = await ref.read(kioskEmergencyExitProvider).pausedUntil();
    } on Object {
      // Хранилище недоступно — паузу узнать нельзя; проверка при нажатии покажет «Не удалось выполнить».
      return;
    }
    if (!mounted || found == null) return;
    final DateTime until = found;
    setState(() => _pause(until));
  }

  void _pause(DateTime until) {
    _pausedUntil = until;
    _failure = KioskExitPaused(until);
    _pauseTimer?.cancel();
    final Duration left = until.difference(ref.read(clockProvider).nowUtc());
    _pauseTimer = Timer(left.isNegative ? Duration.zero : left, () {
      _tick?.cancel();
      _tick = null;
      if (!mounted) return;
      setState(() {
        _pausedUntil = null;
        _failure = null;
      });
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 15), (Timer _) {
      if (mounted && _paused) setState(() {});
    });
  }

  void _add(String digit) {
    if (_busy || _paused || _code.length >= KioskEmergencyExit.codeLength) return;
    setState(() {
      _code += digit;
      if (_failure is KioskExitRejected || _failure is KioskExitFailed) _failure = null;
    });
  }

  void _backspace() {
    if (_busy || _paused || _code.isEmpty) return;
    setState(() => _code = _code.substring(0, _code.length - 1));
  }

  void _close() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  Future<void> _submit() async {
    if (_busy || _paused || _code.length != KioskEmergencyExit.codeLength) return;
    final String code = _code;
    setState(() => _busy = true);
    final KioskExitOutcome outcome;
    try {
      outcome = await ref.read(kioskEmergencyExitProvider).submit(code);
    } on Object {
      // Сбой проверки (хранилище недоступно, хэш не вычислен) — код не принят и не признан неверным: «Не удалось
      // выполнить. Повторите», попытка повторяется вручную.
      if (mounted) {
        setState(() {
          _busy = false;
          _code = '';
          _failure = const KioskExitFailed();
          _shake++;
        });
      }
      return;
    }
    if (!mounted) return;
    switch (outcome) {
      case KioskExitDone():
        Navigator.of(context).pop();
      case KioskExitRejected() || KioskExitFailed():
        setState(() {
          _busy = false;
          _code = '';
          _failure = outcome;
          _shake++;
        });
      case KioskExitPaused(:final DateTime until):
        setState(() {
          _busy = false;
          _code = '';
          _shake++;
          _pause(until);
        });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _errorText(AppLocalizations l10n) => switch (_failure) {
    KioskExitRejected(attemptsLeft: final int n) => l10n.kiosk_exit_code_invalid(n),
    KioskExitRejected() => l10n.error_kiosk_exit_code_invalid,
    KioskExitFailed() => l10n.error_internal,
    KioskExitPaused(:final DateTime until) => l10n.kiosk_exit_locked(_minutesLeft(until)),
    KioskExitDone() || null => null,
  };

  int _minutesLeft(DateTime until) {
    final int seconds = until.difference(ref.read(clockProvider).nowUtc()).inSeconds;
    return seconds <= 0 ? 1 : (seconds + 59) ~/ 60;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final double screen = MediaQuery.sizeOf(context).width; // money-double: allow — геометрия UI (lp)
    final double width = (screen - 32).clamp(280.0, 480.0); // money-double: allow — геометрия UI (lp)
    final String? error = _errorText(l10n);
    final bool canSubmit = !_busy && !_paused && _code.length == KioskEmergencyExit.codeLength;
    return Center(
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: l10n.kiosk_exit_title,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Material(
            key: KioskEmergencyExitDialog.dialogKey,
            type: MaterialType.transparency,
            child: Container(
              width: width,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.all(context.radii.lg),
                boxShadow: context.elevation.e3,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(l10n.kiosk_exit_title, style: context.text.h3.copyWith(color: c.textPrimary)),
                    const SizedBox(height: 16),
                    Text(l10n.kiosk_exit_code_label, style: context.text.label.copyWith(color: c.textSecondary)),
                    const SizedBox(height: 8),
                    DsShake(
                      trigger: _shake,
                      child: _CodeSlots(entered: _code.length, error: error != null),
                    ),
                    if (error != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          error,
                          key: KioskEmergencyExitDialog.errorKey,
                          style: context.text.label.copyWith(color: c.error),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Center(
                      // Узкое окно (на compact режим планшета не включается): клавиатура уменьшается, а не обрезается.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: KioskKeypad(
                          length: KioskEmergencyExit.codeLength,
                          entered: _code.length,
                          enabled: !_busy && !_paused,
                          backspaceLabel: l10n.qty_key_backspace_a11y,
                          onDigit: _add,
                          onBackspace: _backspace,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        AppButton(
                          key: KioskEmergencyExitDialog.cancelKey,
                          label: l10n.ds_button_cancel,
                          variant: AppButtonVariant.text,
                          onPressed: _busy ? null : _close,
                        ),
                        AppButton(
                          key: KioskEmergencyExitDialog.submitKey,
                          label: l10n.kiosk_exit_submit,
                          loading: _busy,
                          onPressed: canSubmit ? () => unawaited(_submit()) : null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Поле кода только для чтения: 8 позиций, введённые цифры скрыты (`obscureText`), `tnum`.
class _CodeSlots extends StatelessWidget {
  const _CodeSlots({required this.entered, required this.error});

  final int entered;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      label: AppLocalizations.of(context).kiosk_exit_code_label,
      value: '$entered / ${KioskEmergencyExit.codeLength}',
      excludeSemantics: true,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: c.surfaceVariant,
          borderRadius: BorderRadius.all(context.radii.md),
          border: Border.all(color: error ? c.error : c.border),
        ),
        alignment: Alignment.center,
        child: Text(
          List<String>.generate(KioskEmergencyExit.codeLength, (int i) => i < entered ? '•' : '–').join(' '),
          style: context.text.h3.copyWith(fontFeatures: DsTypography.numeric, color: c.textPrimary),
        ),
      ),
    );
  }
}
