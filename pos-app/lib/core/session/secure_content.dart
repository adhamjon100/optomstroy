// Защита содержимого экранов ввода OTP и PIN (02 SCR-02.4; Q-181; D_spec_questions AU-16): вход (SCR-02),
// разблокировка (SCR-08), step-up, оверлей блокировки сессии, установка и смена PIN (ревью E, E-security-4).
//
// Пока виджет смонтирован: Android — `FLAG_SECURE` окна (порт [SecureScreen]); на всех платформах при уходе
// приложения из активного состояния содержимое закрывается непрозрачной заливкой — в переключателе приложений
// не видно код/PIN (мобильные: `inactive`/`hidden`/`paused`; Windows — только `hidden`/`paused`, чтобы не
// закрывать экран при потере фокуса окна). Вложенные экраны считаются счётчиком: флаг снимается последним.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/session/secure_screen.dart';

/// Защищённая область ввода PIN/OTP. Порт берётся из ближайшего `ProviderScope`; без него (диалог в тесте
/// без Riverpod) — [NoSecureScreen]: заливка в фоне работает и без системного флага.
class SecureContent extends StatefulWidget {
  const SecureContent({super.key, required this.child});

  /// Ключ заливки, закрывающей содержимое в фоне.
  static const Key coverKey = ValueKey<String>('secure-content-cover');

  final Widget child;

  /// Сколько экземпляров смонтировано (для тестов).
  @visibleForTesting
  static int get activeCount => _active;

  static int _active = 0;

  @override
  State<SecureContent> createState() => _SecureContentState();
}

class _SecureContentState extends State<SecureContent> with WidgetsBindingObserver {
  late final SecureScreen _port;
  bool _covered = false;

  static bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _port = _portOf(context);
    WidgetsBinding.instance.addObserver(this);
    if (SecureContent._active++ == 0) unawaited(_port.setSecure(enabled: true));
  }

  static SecureScreen _portOf(BuildContext context) {
    try {
      return ProviderScope.containerOf(context, listen: false).read(secureScreenProvider);
    } on StateError {
      return const NoSecureScreen();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (--SecureContent._active == 0) unawaited(_port.setSecure(enabled: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool cover = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.detached => false,
      AppLifecycleState.inactive => _mobile,
      AppLifecycleState.hidden || AppLifecycleState.paused => true,
    };
    if (cover != _covered && mounted) setState(() => _covered = cover);
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: <Widget>[
      widget.child,
      if (_covered)
        Positioned.fill(
          child: ColoredBox(key: SecureContent.coverKey, color: Theme.of(context).scaffoldBackgroundColor),
        ),
    ],
  );
}
