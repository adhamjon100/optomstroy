import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Буфер обмена платформы для widget-тестов (канал `SystemChannels.platform`): [text] на чтение, счётчик чтений.
/// [denied] — чтение отклоняется, как в браузере без разрешения `clipboard-read` (`PlatformException` `paste_fail`,
/// движок web `ClipboardMessageHandler`). Снимается в `tearDown` теста.
final class FakeClipboard {
  /// Подменяет канал на время теста [tester].
  FakeClipboard(WidgetTester tester, this.text, {this.denied = false}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        if (denied) throw PlatformException(code: 'paste_fail', message: 'Clipboard.getData failed');
        return <String, Object?>{'text': text};
      }
      if (call.method == 'Clipboard.hasStrings') return <String, Object?>{'value': text.isNotEmpty};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  /// Текст буфера.
  String text;

  /// Чтение отклоняется.
  bool denied;

  /// Сколько раз буфер прочитан.
  int reads = 0;
}

/// `Ctrl+V` с клавиатуры (Windows, Android, Linux — `control`).
Future<void> pressCtrlV(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Вставка [pasted] в [old] так, как её применяют `Ctrl+V` / «Вставить» Flutter и вставка браузера: замена выделения,
/// курсор после вставленного текста.
TextEditingValue pasteInto(TextEditingValue old, String pasted) {
  final TextSelection sel = old.selection.isValid ? old.selection : TextSelection.collapsed(offset: old.text.length);
  final String text = old.text.replaceRange(sel.start, sel.end, pasted);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: sel.start + pasted.length),
  );
}
