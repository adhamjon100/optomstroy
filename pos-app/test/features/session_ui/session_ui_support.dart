// Обвязка виджет-тестов слоя сессии: тема B, локаль ru, размер окна, SessionGate в MaterialApp.builder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/session_ui/presentation/session_gate.dart';

const Size compactSize = Size(390, 844);
const Size expandedSize = Size(1280, 800);

void setWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// Приложение с [home] под SessionGate (как в app/app.dart: `MaterialApp.builder`).
Widget gatedApp(ProviderContainer container, Widget home, {SessionLockScreenBuilder? lockScreenBuilder}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: SessionGate(lockScreenBuilder: lockScreenBuilder, child: child!),
        ),
        home: home,
      ),
    );

/// Отдельный виджет в теме B (без SessionGate).
Widget themed(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  locale: const Locale('ru'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  debugShowCheckedModeBanner: false,
  builder: (context, app) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
  home: Scaffold(body: child),
);

/// Ввести цифры на экранном нампаде PinField.
Future<void> tapPin(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.text(d).last);
    await tester.pump();
  }
}

/// Несколько кадров, чтобы цепочка интерсепторов Dio и setState дошли до конца.
Future<void> frames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Экран с состоянием (черновик в поле, счётчик) — проверка сохранения под overlay.
class DraftScreen extends StatefulWidget {
  const DraftScreen({super.key});

  static const Key fieldKey = Key('draft-field');
  static const Key incrementKey = Key('draft-increment');

  @override
  State<DraftScreen> createState() => DraftScreenState();
}

class DraftScreenState extends State<DraftScreen> {
  final TextEditingController controller = TextEditingController();
  int counter = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: <Widget>[
        TextField(key: DraftScreen.fieldKey, controller: controller),
        Text('counter:$counter'),
        TextButton(key: DraftScreen.incrementKey, onPressed: () => setState(() => counter++), child: const Text('inc')),
      ],
    ),
  );
}
