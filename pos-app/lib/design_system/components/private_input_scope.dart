import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/web_field_context_menu.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/ds_toolbar_buttons.dart';

/// Область «общее устройство» `PrivateInputScope` (03 §9.74; ADR-115 п. 27; DS-099, DS-100; 10 KIOSK-021,
/// 11 PRIV-033).
///
/// Не визуальный компонент, а [InheritedWidget]: своих состояний и токенов нет. Задаётся один раз — в `builder`
/// `MaterialApp.router` (`app/app.dart`) и включена только в режиме `AppMode.kiosk`; построитель оборачивает
/// `Navigator`, поэтому область наследуют все маршруты, нижние листы и диалоги корневого навигатора.
///
/// `AppTextField`, `PhoneField`, `OtpField` и `SearchBar` читают её сами ([of]); параметра «общее устройство» у
/// вызова нет. Внутри области у их `TextField`: `enableSuggestions: false`, `autocorrect: false`,
/// `enableIMEPersonalizedLearning: false`, `autofillHints: null`, `enableInteractiveSelection: false` (нет
/// выделения, ручек и вставки `Ctrl+V`), `contextMenuBuilder: null`. Поля номера и кодов — без системной клавиатуры
/// (`readOnly` + `TextInputType.none`), их вводит `KioskKeypad`; поиск и прочие поля — с системной клавиатурой.
/// Буфер обмена компоненты не читают; очищает его сброс планшета (FLOW-045).
///
/// Вне области (сотрудник, покупатель на своём телефоне) и при [enabled] `false` компоненты передают `TextField`
/// те же значения, что и до редакции 1.19 ([defaultContextMenuBuilder], [defaultAutofillHints]) — паритет функций;
/// в веб-сборке меню поля — [webContextMenuBuilder] (то же меню, «Вставить» с подсказкой при отказе браузера).
class PrivateInputScope extends InheritedWidget {
  /// Создаёт область; [enabled] `false` — как без области (корень держит виджет всегда, чтобы смена режима
  /// не пересоздавала `Navigator`).
  const PrivateInputScope({super.key, this.enabled = true, required super.child});

  /// Включена ли область.
  final bool enabled;

  /// Внутри ли [context] включённой области; без области — `false`.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PrivateInputScope>()?.enabled ?? false;

  /// Контекстное меню `TextField` по умолчанию (то же значение, что у `TextField()` без параметра) — вне области.
  static final EditableTextContextMenuBuilder? defaultContextMenuBuilder = const TextField().contextMenuBuilder;

  /// `autofillHints` `TextField` по умолчанию (пустой список) — вне области.
  static const List<String> defaultAutofillHints = <String>[];

  /// Контекстное меню поля: в области — нет; вне — по умолчанию `TextField`, в веб-сборке — [webContextMenuBuilder].
  static EditableTextContextMenuBuilder? contextMenuBuilderFor({required bool private}) =>
      private ? null : (kIsWeb ? webContextMenuBuilder : defaultContextMenuBuilder);

  /// Меню поля в веб-сборке (веб-демо; 15 ADR-113 п. 1, уточнение 2026-11-08): те же пункты и тот же вид, что у меню
  /// `TextField` по умолчанию, но «Вставить» не оставляет меню открытым при отказе браузера, а подписи кнопок — шрифтом
  /// приложения Inter (`dsToolbarButtons`: без него движок запрашивает запасной шрифт Noto Sans SC с сайта — 404).
  ///
  /// В браузере «Вставить» меню Flutter читает буфер обмена через `navigator.clipboard.readText()`: нужно
  /// разрешение `clipboard-read` (запрос Chrome и Edge при первом нажатии; Firefox — своя кнопка «Вставить»).
  /// Отказ, закрытый запрос или браузер без чтения буфера — `PlatformException` (`paste_fail`): меню закрывается, а
  /// снекбар (`ds_paste_blocked_hint`) подсказывает `Ctrl+V` (на Mac — `⌘V`) или меню в самом поле — меню браузера
  /// над текстом поля в фокусе; вставка браузера разрешения не требует.
  ///
  /// Над полем в фокусе с этим меню точка входа веб-демо включает меню браузера (`app/demo/demo_context_menu.dart`;
  /// меню отмечено `WebFieldContextMenu.fieldMenu`) — пока `WebFieldContextMenu.browserMenuOverField` `true`, меню
  /// поля пустое, чтобы не открылось второе меню. Над полями с другим меню меню браузера не включается.
  static final EditableTextContextMenuBuilder webContextMenuBuilder = WebFieldContextMenu.fieldMenu(_webContextMenu);

  static Widget _webContextMenu(BuildContext context, EditableTextState editableTextState) =>
      ValueListenableBuilder<bool>(
        valueListenable: WebFieldContextMenu.browserMenuOverField,
        builder: (BuildContext context, bool browserMenu, Widget? _) => browserMenu
            ? const SizedBox.shrink()
            // Подписи кнопок — шрифтом приложения (`dsToolbarButtons`): у кнопок Flutter на настольных платформах и
            // iOS шрифт не задан, и движок веб-сборки запрашивал бы для кириллицы запасной шрифт с сайта (404).
            : AdaptiveTextSelectionToolbar(
                anchors: editableTextState.contextMenuAnchors,
                children: dsToolbarButtons(context, <ContextMenuButtonItem>[
                  for (final ContextMenuButtonItem item in editableTextState.contextMenuButtonItems)
                    if (item.type == ContextMenuButtonType.paste)
                      item.copyWith(onPressed: () => unawaited(_pasteOrHint(editableTextState)))
                    else
                      item,
                ]),
              ),
      );

  static Future<void> _pasteOrHint(EditableTextState state) async {
    final BuildContext context = state.context;
    try {
      await state.pasteText(SelectionChangedCause.toolbar);
    } on PlatformException {
      if (!context.mounted) return;
      state.hideToolbar();
      if (ScaffoldMessenger.maybeOf(context) == null) return;
      AppSnackbar.show(context, message: AppLocalizations.of(context).ds_paste_blocked_hint);
    }
  }

  @override
  bool updateShouldNotify(PrivateInputScope oldWidget) => oldWidget.enabled != enabled;
}
