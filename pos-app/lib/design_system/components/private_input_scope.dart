import 'package:flutter/material.dart';

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
/// те же значения, что и до редакции 1.19 ([defaultContextMenuBuilder], [defaultAutofillHints]) — паритет функций.
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

  /// Контекстное меню поля: в области — нет, вне — по умолчанию `TextField`.
  static EditableTextContextMenuBuilder? contextMenuBuilderFor({required bool private}) =>
      private ? null : defaultContextMenuBuilder;

  @override
  bool updateShouldNotify(PrivateInputScope oldWidget) => oldWidget.enabled != enabled;
}
