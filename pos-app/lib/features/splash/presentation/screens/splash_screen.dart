import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/splash/presentation/notifiers/splash_decision.dart';
import 'package:optomstroy/features/splash/presentation/widgets/splash_logo.dart';

/// SCR-00 Splash (`/splash`; 02 SCR-00; 03 §12; RM-D-007).
///
/// Показывает `SplashLogo` (ANIM-001, 600 мс) и параллельно ждёт снимок сессии
/// ([splashSnapshotProvider]); переход — в момент max(решение, конец ANIM-001), без
/// искусственных пауз (при reduce-motion — сразу после решения). Индикатор — только если
/// решение не принято за 400 мс, подпись «Проверяем сессию…» — после 2 с. Сбой
/// инициализации после автоповтора — `ErrorState` «Не удалось запустить приложение».
/// Персонаж на Splash не показывается (03 §12.1).
class SplashScreen extends ConsumerStatefulWidget {
  /// Создаёт экран Splash.
  const SplashScreen({super.key});

  /// Ключ корневого виджета экрана (smoke-тест и integration_test).
  static const Key screenKey = Key('scr-00-splash');
  static const Key progressKey = Key('scr-00-progress');
  static const Key statusKey = Key('scr-00-status');
  static const Key versionKey = Key('scr-00-version');
  static const Key initErrorKey = Key('scr-00-init-error');

  /// Минимальный показ логотипа (`ds.motion.splashLogo`).
  static const Duration logoDuration = Duration(milliseconds: 600);

  /// Индикатор — если решения нет за 400 мс (UI-00-002).
  static const Duration progressAfter = Duration(milliseconds: 400);

  /// Подпись статуса — после 2 с (UI-00-003).
  static const Duration statusAfter = Duration(seconds: 2);

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  Timer? _progressTimer;
  Timer? _statusTimer;
  Timer? _logoTimer;
  bool _logoDone = false;
  bool _showProgress = false;
  bool _showStatus = false;
  bool _navigated = false;
  bool _autoRetried = false;

  @override
  void initState() {
    super.initState();
    // Индикатор и подпись — только пока решение не принято (UI-00-002/003).
    _progressTimer = Timer(SplashScreen.progressAfter, () {
      if (!_decided) {
        _set(() => _showProgress = true);
      }
    });
    _statusTimer = Timer(SplashScreen.statusAfter, () {
      if (!_decided) {
        _set(() => _showStatus = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _logoTimer ??= Timer(context.motion.reduceMotion ? Duration.zero : SplashScreen.logoDuration, () {
      _logoDone = true;
      _tryNavigate();
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _statusTimer?.cancel();
    _logoTimer?.cancel();
    super.dispose();
  }

  bool get _decided => mounted && ref.read(splashSnapshotProvider) is AsyncData<SplashSnapshot>;

  void _set(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }

  void _tryNavigate() {
    if (_navigated || !_logoDone || !mounted) {
      return;
    }
    final AsyncValue<SplashSnapshot> snapshot = ref.read(splashSnapshotProvider);
    if (snapshot case AsyncData<SplashSnapshot>(:final SplashSnapshot value)) {
      _navigated = true;
      _progressTimer?.cancel();
      _statusTimer?.cancel();
      GoRouter.maybeOf(context)?.go(decideSplash(value).location);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<SplashSnapshot> snapshot = ref.watch(splashSnapshotProvider);
    ref.listen<AsyncValue<SplashSnapshot>>(splashSnapshotProvider, (
      AsyncValue<SplashSnapshot>? _,
      AsyncValue<SplashSnapshot> next,
    ) {
      if (next is AsyncData<SplashSnapshot>) {
        _tryNavigate();
      } else if (next is AsyncError<SplashSnapshot> && !_autoRetried) {
        // Один автоповтор инициализации, затем — UI-00-005 (SEC-086).
        _autoRetried = true;
        ref.invalidate(splashSnapshotProvider);
      }
    });

    final bool initError = snapshot is AsyncError<SplashSnapshot> && _autoRetried && !snapshot.isLoading;
    final bool large = context.windowClass != WindowClass.compact;
    final Widget content = initError
        ? ErrorState.fullScreen(
            key: SplashScreen.initErrorKey,
            title: l10n.splash_init_error_title,
            message: l10n.splash_init_error_body,
            onRetry: () => ref.invalidate(splashSnapshotProvider),
          )
        : Align(
            // Центр со смещением вверх на 8 % высоты (UI-00-001).
            alignment: const Alignment(0, -0.16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SplashLogo(),
                SizedBox(height: context.space.s7),
                SizedBox(
                  width: large ? 160 : 120,
                  height: 2,
                  child: _showProgress && !_navigated
                      ? const AppProgress.linear(key: SplashScreen.progressKey, thin: true)
                      : null,
                ),
                SizedBox(height: context.space.s2),
                SizedBox(
                  height: 16,
                  child: _showProgress && _showStatus && !_navigated
                      ? Text(
                          l10n.splash_status_checking,
                          key: SplashScreen.statusKey,
                          style: context.text.caption.copyWith(color: context.colors.textSecondary),
                        )
                      : null,
                ),
              ],
            ),
          );
    return Scaffold(
      key: SplashScreen.screenKey,
      backgroundColor: context.colors.surface,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: content),
            Positioned(
              left: 0,
              right: 0,
              bottom: context.space.s4,
              child: _Version(l10n: l10n),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка версии (UI-00-004): «Версия 1.0.0 (120)» из `X-App-Version` клиента.
class _Version extends ConsumerWidget {
  const _Version({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? appVersion = ref.watch(_appVersionProvider);
    if (appVersion == null) {
      return const SizedBox.shrink();
    }
    final List<String> parts = appVersion.split('+');
    final String build = parts.length > 1 ? parts[1] : '';
    return Text(
      l10n.splash_version(build, parts.first),
      key: SplashScreen.versionKey,
      textAlign: TextAlign.center,
      style: context.text.caption.copyWith(color: context.colors.textSecondary),
    );
  }
}

/// Версия из `clientMetaProvider`; `null`, если метаданные не загружены (тесты, сбой платформы).
final _appVersionProvider = Provider<String?>((ref) {
  try {
    return ref.watch(clientMetaProvider).appVersion;
  } on Object {
    return null;
  }
});
