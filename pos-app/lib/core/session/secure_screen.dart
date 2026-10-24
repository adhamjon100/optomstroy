// Защита содержимого экранов ввода OTP и PIN (02 SCR-02.4, SCR-08, стр. «Захват экрана»; 11 SEC-097; Q-181;
// D_spec_questions AU-16). Порт — в core/session, чтобы им пользовались все экраны ввода PIN/OTP (вход, разблокировка,
// step-up, оверлей блокировки, установка PIN), а не только фича auth (ревью E, E-security-4).
//
// Android — `WindowManager.LayoutParams.FLAG_SECURE` окна приложения (нет скриншотов/записи экрана и миниатюры в
// переключателе приложений): реализация `ChannelSecureScreen` фичи auth (канал `kg.optomstroy/biometric_crypto`),
// подключается `authBindings`. Остальные платформы — без системного флага: содержимое закрывает [SecureContent]
// при уходе приложения в фон. До подключения — [NoSecureScreen].
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Включение/выключение системной защиты содержимого окна.
abstract interface class SecureScreen {
  /// `true` — запретить снимки экрана и миниатюру в переключателе приложений.
  Future<void> setSecure({required bool enabled});
}

/// Платформа без системного флага (тесты, Windows, iOS).
final class NoSecureScreen implements SecureScreen {
  const NoSecureScreen();

  @override
  Future<void> setSecure({required bool enabled}) async {}
}

/// Защита содержимого экранов OTP/PIN (AU-16): Android — `FLAG_SECURE`; по умолчанию — без системного флага.
final secureScreenProvider = Provider<SecureScreen>((ref) => const NoSecureScreen());
