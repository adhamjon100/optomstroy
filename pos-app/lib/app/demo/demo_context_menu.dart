// Меню браузера по правой кнопке в веб-демо (15 ADR-113 п. 1; уточнение 2026-11-08 — вставка на экранах входа).
//
// Меню браузера отключено для всей страницы (`BrowserContextMenu.disableContextMenu()`), иначе оно перекрывает
// контекстные меню приложения (строки клиентов, заказов, уведомлений, копирование номеров). Но тогда над полем ввода
// Flutter рисует своё меню, и его «Вставить» читает буфер через `navigator.clipboard.readText()` — нужно разрешение
// `clipboard-read`; без него ничего не вставляется (WEB-KI-14).
//
// [DemoBrowserContextMenu] включает меню браузера в движке, когда указатель нажат над полем ввода дизайн-системы в
// фокусе, где можно вставить текст (`RenderEditable`: фокус, не `readOnly`, выделение включено; меню поля —
// `PrivateInputScope.webContextMenuBuilder`, отмеченное `WebFieldContextMenu.fieldMenu`). Над таким полем событие
// `contextmenu` получает скрытый элемент ввода движка, и браузер показывает меню поля с «Вставить» — это вставка
// браузера, разрешение не нужно (тот же путь, что у `Ctrl+V`). Меню Flutter при этом не рисуется:
// `WebFieldContextMenu.browserMenuOverField` = `true`, и меню поля дизайн-системы пустое. Над остальным (и над
// полями планшета магазина: `readOnly`, без выделения) меню браузера снова выключено. Меню браузера — только у
// полей, чьё меню поля пустеет (`webContextMenuBuilder`), иначе открылись бы два меню: у полей с меню `TextField` по
// умолчанию (поле ввода даты `showDatePicker` / `showDateRangePicker`) остаётся одно меню Flutter, как прежде, — его
// «Вставить» читает буфер с разрешения браузера и при отказе ничего не вставляет.
//
// Решение — при нажатии указателя (`PointerDownEvent`), синхронно: движок обрабатывает сообщение
// `flutter/contextmenu` сразу, раньше, чем браузер пришлёт `contextmenu` (после pointerdown, на Windows — после
// pointerup). Включают меню браузера правая кнопка мыши, касание и перо (долгое нажатие в мобильном браузере);
// левая кнопка его не включает, а только выключает вне поля. Сообщение уходит прямо в канал
// `SystemChannels.contextMenu`, флаг фреймворка `BrowserContextMenu.enabled` не меняется (почему —
// `core/utils/web_field_context_menu.dart`).
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException, SystemChannels;
import 'package:flutter/widgets.dart' show ContextMenuController, EditableTextState, FocusManager;
import 'package:logging/logging.dart';
import 'package:optomstroy/core/utils/web_field_context_menu.dart';

final Logger _log = Logger('demo');

/// Переключатель меню браузера: включает его над полем ввода дизайн-системы в фокусе и выключает над остальным.
final class DemoBrowserContextMenu {
  /// Создаёт переключатель; [enable] / [disable] (по умолчанию — сообщения движку) и [overField] подменяют тесты.
  DemoBrowserContextMenu({
    Future<void> Function()? enable,
    Future<void> Function()? disable,
    bool Function(Offset position, int viewId)? editableAt,
    ValueNotifier<bool>? overField,
  }) : _enable = enable ?? _engineEnable,
       _disable = disable ?? _engineDisable,
       _editableAt = editableAt ?? pasteableEditableAt,
       _overField = overField ?? WebFieldContextMenu.browserMenuOverField;

  final Future<void> Function() _enable;
  final Future<void> Function() _disable;
  final bool Function(Offset position, int viewId) _editableAt;
  final ValueNotifier<bool> _overField;

  static Future<void> _engineEnable() => SystemChannels.contextMenu.invokeMethod<void>('enableContextMenu');
  static Future<void> _engineDisable() => SystemChannels.contextMenu.invokeMethod<void>('disableContextMenu');

  /// Включено ли меню браузера (по последнему решению); на старте меню отключено.
  bool get enabled => _enabled;
  bool _enabled = false;

  bool _attached = false;

  /// Начать следить за нажатиями указателя.
  void attach() {
    if (_attached) return;
    _attached = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(handlePointer);
  }

  /// Перестать следить; меню поля дизайн-системы снова рисуется.
  void detach() {
    if (!_attached) return;
    _attached = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(handlePointer);
    _overField.value = false;
  }

  /// Обработчик глобального маршрута указателя.
  @visibleForTesting
  void handlePointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final bool over = _editableAt(event.position, event.viewId);
    final bool mouse = event.kind == PointerDeviceKind.mouse;
    final bool secondary = mouse && (event.buttons & kSecondaryMouseButton) != 0;
    // Левая кнопка мыши меню браузера не включает, а только выключает вне поля.
    final bool want = mouse && !secondary ? _enabled && over : over;
    // Правый щелчок закрывает меню поля, открытое прошлым нажатием: `EditableText.toggleToolbar` этого щелчка откроет
    // нужное заново, а не закроет старое. Выключение меню браузера закрывает и пустое меню поля, чтобы оно не стало
    // меню Flutter без нового нажатия.
    if (secondary || (_enabled && !want)) ContextMenuController.removeAny();
    _overField.value = want;
    if (want == _enabled) return;
    _enabled = want;
    unawaited(_apply(want ? _enable : _disable));
  }

  static Future<void> _apply(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException catch (e) {
      _log.warning('меню браузера не переключено: ${e.code}');
    } on MissingPluginException catch (e) {
      _log.warning('меню браузера не переключено: ${e.message}');
    }
  }

  /// Есть ли под [position] поле ввода в фокусе, в которое можно вставить текст: `RenderEditable` с фокусом, не
  /// `readOnly` и с включённым выделением (у полей `PrivateInputScope` выделение выключено), и меню этого поля
  /// пустеет над меню браузера (`WebFieldContextMenu.hidesForBrowserMenu`) — иначе открылись бы два меню.
  static bool pasteableEditableAt(Offset position, int viewId) {
    // Фокус `EditableText` — виджет `Focus` внутри `EditableTextState`: его состояние — предок контекста фокуса.
    final EditableTextState? focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (focused == null || !WebFieldContextMenu.hidesForBrowserMenu(focused.widget.contextMenuBuilder)) return false;
    final HitTestResult result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, position, viewId);
    for (final HitTestEntry entry in result.path) {
      final HitTestTarget target = entry.target;
      if (target is RenderEditable && target.hasFocus && !target.readOnly && target.selectionEnabled) return true;
    }
    return false;
  }
}
