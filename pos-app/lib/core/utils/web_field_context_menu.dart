import 'package:flutter/widgets.dart' show EditableTextContextMenuBuilder, ValueNotifier;

/// Меню браузера над полем ввода в веб-демо (15 ADR-113 п. 1, уточнение 2026-11-08 — вставка на экранах входа).
///
/// В веб-демо меню браузера по правой кнопке отключено для всей страницы, иначе оно перекрывает контекстные меню
/// приложения. Точка входа веб-демо (`app/demo/demo_context_menu.dart`) включает его в движке только на нажатие
/// указателя над полем ввода в фокусе, чьё меню поля отмечено [fieldMenu] — там браузер показывает меню поля с
/// «Вставить» без разрешения `clipboard-read` — и ставит [browserMenuOverField] в `true`. Меню поля дизайн-системы в
/// веб-сборке (`PrivateInputScope.webContextMenuBuilder`, отмечено [fieldMenu]) в это время ничего не рисует, чтобы
/// рядом с меню браузера не открылось второе. Над полями с другим меню (поле ввода даты `showDatePicker`, любое
/// `TextField` с меню по умолчанию) меню браузера не включается — у них остаётся одно меню Flutter, как прежде.
///
/// Флаг фреймворка `BrowserContextMenu.enabled` не меняется (остаётся `false`): `EditableText` запоминает его, когда
/// создаёт оверлей выделения, и с `true` у поля до потери фокуса не было бы меню Flutter над его краями (префикс,
/// отступы), а обновляется он с задержкой — меню Flutter успевало бы открыться вместе с меню браузера.
///
/// Вне веб-демо значение всегда `false`.
abstract final class WebFieldContextMenu {
  /// Включено ли сейчас меню браузера над полем ввода в фокусе (по последнему нажатию указателя).
  static final ValueNotifier<bool> browserMenuOverField = ValueNotifier<bool>(false);

  static final Set<EditableTextContextMenuBuilder> _fieldMenus = <EditableTextContextMenuBuilder>{};

  /// Отмечает [builder] как меню поля, которое пустеет, пока [browserMenuOverField] `true`; возвращает [builder].
  ///
  /// Отмечает дизайн-система (`PrivateInputScope.webContextMenuBuilder`): точка входа веб-демо её не импортирует
  /// (`scripts/check_layers.py` DM-01) и узнаёт такие поля по [hidesForBrowserMenu].
  static EditableTextContextMenuBuilder fieldMenu(EditableTextContextMenuBuilder builder) {
    _fieldMenus.add(builder);
    return builder;
  }

  /// Пустеет ли меню поля [builder], пока над полем включено меню браузера (отмечено [fieldMenu]); `null` — нет.
  static bool hidesForBrowserMenu(EditableTextContextMenuBuilder? builder) =>
      builder != null && _fieldMenus.contains(builder);
}
