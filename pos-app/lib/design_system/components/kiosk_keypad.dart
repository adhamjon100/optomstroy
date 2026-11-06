import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Экранная цифровая клавиатура `KioskKeypad` (03 §9.74; ADR-115 п. 27; DS-101; A11Y-023).
///
/// Только для полей номера телефона и кодов на планшете магазина: у этих полей системная клавиатура не открывается
/// (`PhoneField` / `OtpField` в `PrivateInputScope` — `readOnly` + `TextInputType.none`), цифры вводит эта клавиатура.
/// Варианты — по [length]: номер (9 цифр после «+996», [phoneLength]), код из SMS (6, [smsCodeLength]),
/// аварийный код выхода (8, [exitCodeLength]).
///
/// Анатомия: сетка 3 × 4 — «1»…«9»; нижний ряд: пустая ячейка · «0» · «стереть» (`backspace` 24 `textSecondary`).
/// Клавиша [keyWidth] × [keyHeight] (цель не меньше 64 × 64), контейнер `surface`, обводка 1 px `borderStrong`,
/// радиус `md`, цифра `h2 24/600 tnum textPrimary`; зазор [gap]; hover — `surfaceHover`; pressed —
/// `surfacePressed`, scale 0.98, 150 мс; недоступная — `disabledBg` / `disabledText`; фокус — кольцо `focus`,
/// Enter / Space — нажатие.
///
/// Чистый виджет дизайн-системы (DS-076): значение хранит вызывающий экран ([entered] — сколько цифр уже введено);
/// клавиатура его не хранит, не логирует и в буфер обмена не пишет. Лишние нажатия (уже [length] цифр) и «стереть»
/// при пустом поле игнорируются; при пустом поле «стереть» недоступна. Долгое нажатие ничего не делает (A11Y-017).
/// Подключённая физическая клавиатура: цифры (в том числе цифрового блока) и Backspace вызывают те же [onDigit] /
/// [onBackspace] — пока клавиатура доступна, её маршрут сверху, а фокус не в редактируемом поле ввода (поиск и
/// прочие поля с системной клавиатурой вводят свои символы сами).
class KioskKeypad extends StatefulWidget {
  /// Создаёт клавиатуру.
  const KioskKeypad({
    super.key,
    required this.length,
    required this.entered,
    required this.onDigit,
    required this.onBackspace,
    required this.backspaceLabel,
    this.enabled = true,
  });

  /// Номер телефона: 9 цифр после «+996» (03 §9.4).
  static const int phoneLength = 9;

  /// Код из SMS: 6 цифр (03 §9.5).
  static const int smsCodeLength = 6;

  /// Аварийный код выхода: 8 цифр (02 SCR-51 UI-51-017).
  static const int exitCodeLength = 8;

  /// Ширина клавиши [ТИПОВО — Q-342].
  static const double keyWidth = 88;

  /// Высота клавиши [ТИПОВО — Q-342]; цель не меньше 64 × 64 (A11Y-023).
  static const double keyHeight = 64;

  /// Зазор между клавишами (`ds.space.3`).
  static const double gap = 12;

  /// Ширина клавиатуры: 3 × 88 + 2 × 12 = 288.
  static const double width = 3 * keyWidth + 2 * gap;

  /// Высота клавиатуры: 4 × 64 + 3 × 12 = 292.
  static const double height = 4 * keyHeight + 3 * gap;

  /// Ключ клавиши цифры [key] (`'0'…'9'`) или стирания (`'backspace'`).
  static Key keyFor(String key) => ValueKey<String>('kiosk-keypad-$key');

  /// Наибольшее число цифр поля (9, 6 или 8).
  final int length;

  /// Сколько цифр уже введено (значение хранит экран).
  final int entered;

  /// Нажата цифра `'0'…'9'` (только пока [entered] < [length]).
  final ValueChanged<String> onDigit;

  /// Нажата «стереть» (только при непустом поле).
  final VoidCallback onBackspace;

  /// Подпись клавиши стирания для диктора (на планшете — `qty_key_backspace_a11y` «стереть»).
  final String backspaceLabel;

  /// Доступна ли клавиатура (`false` — запрос кода, «Отправляем заявку…», пауза аварийного выхода).
  final bool enabled;

  @override
  State<KioskKeypad> createState() => _KioskKeypadState();
}

class _KioskKeypadState extends State<KioskKeypad> {
  static final Map<LogicalKeyboardKey, String> _hardwareDigits = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
    LogicalKeyboardKey.numpad0: '0',
    LogicalKeyboardKey.numpad1: '1',
    LogicalKeyboardKey.numpad2: '2',
    LogicalKeyboardKey.numpad3: '3',
    LogicalKeyboardKey.numpad4: '4',
    LogicalKeyboardKey.numpad5: '5',
    LogicalKeyboardKey.numpad6: '6',
    LogicalKeyboardKey.numpad7: '7',
    LogicalKeyboardKey.numpad8: '8',
    LogicalKeyboardKey.numpad9: '9',
  };

  ModalRoute<Object?>? _route;

  bool get _canAdd => widget.enabled && widget.entered < widget.length;
  bool get _canErase => widget.enabled && widget.entered > 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  void _digit(String digit) {
    if (_canAdd) widget.onDigit(digit);
  }

  void _backspace() {
    if (_canErase) widget.onBackspace();
  }

  /// Физическая клавиатура → те же действия, что у экранных клавиш (03 §9.74 «Поведение»).
  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || !widget.enabled || event is KeyUpEvent) return false;
    if (_route != null && !_route!.isCurrent) return false;
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed || keyboard.isAltPressed) return false;
    if (_focusInEditableField()) return false;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return true;
    }
    final String? digit = _hardwareDigits[event.logicalKey];
    if (digit == null || event is! KeyDownEvent) return false;
    _digit(digit);
    return true;
  }

  /// Фокус в поле, которое принимает ввод само (не `readOnly`): его символы клавиатура не перехватывает.
  static bool _focusInEditableField() {
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null || !focused.mounted) return false;
    final EditableText? field = focused.findAncestorWidgetOfExactType<EditableText>();
    return field != null && !field.readOnly;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    Widget digit(String d) => _KioskKey(
      key: KioskKeypad.keyFor(d),
      label: d,
      enabled: widget.enabled,
      onTap: () => _digit(d),
      builder: (bool enabled) => Text(
        d,
        textScaler: TextScaler.noScaling,
        style: context.text.h2.copyWith(
          fontFeatures: DsTypography.numeric,
          color: enabled ? c.textPrimary : c.disabledText,
        ),
      ),
    );
    Widget row(List<Widget> keys) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < keys.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: KioskKeypad.gap), keys[i]],
      ],
    );
    return SizedBox(
      width: KioskKeypad.width,
      height: KioskKeypad.height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          row(<Widget>[digit('1'), digit('2'), digit('3')]),
          const SizedBox(height: KioskKeypad.gap),
          row(<Widget>[digit('4'), digit('5'), digit('6')]),
          const SizedBox(height: KioskKeypad.gap),
          row(<Widget>[digit('7'), digit('8'), digit('9')]),
          const SizedBox(height: KioskKeypad.gap),
          row(<Widget>[
            const SizedBox(width: KioskKeypad.keyWidth, height: KioskKeypad.keyHeight),
            digit('0'),
            _KioskKey(
              key: KioskKeypad.keyFor('backspace'),
              label: widget.backspaceLabel,
              enabled: widget.enabled && widget.entered > 0,
              onTap: _backspace,
              builder: (bool enabled) =>
                  Icon(Icons.backspace_outlined, size: 24, color: enabled ? c.textSecondary : c.disabledText),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Клавиша 88 × 64 (03 §9.74): `surface` + обводка `borderStrong`, hover `surfaceHover`, pressed `surfacePressed`
/// + scale 0.98 за 150 мс, недоступная — `disabledBg`.
class _KioskKey extends StatelessWidget {
  const _KioskKey({required this.label, required this.enabled, required this.onTap, required this.builder, super.key});

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Widget Function(bool enabled) builder;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Duration fast = context.motion.of(context.motion.fast);
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: DsInteractive(
        enabled: enabled,
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: AnimatedScale(
            scale: s.pressed && enabled ? 0.98 : 1,
            duration: fast,
            child: AnimatedContainer(
              duration: fast,
              width: KioskKeypad.keyWidth,
              height: KioskKeypad.keyHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: !enabled
                    ? c.disabledBg
                    : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface)),
                borderRadius: radius,
                border: Border.all(color: enabled ? c.borderStrong : c.disabledText),
              ),
              child: builder(enabled),
            ),
          ),
        ),
      ),
    );
  }
}
