# features/home

Экраны: SCR-50 `/home?view=&sort=` — главный экран клиента-покупателя (`customer`, ядро v1.9 §24.2).
Задача: RM-E-017 (13 §3.5).

- `presentation/screens/customer_home_screen.dart` → `CustomerHomeScreen` (путь, класс и конструктор фиксированы
  маршрутом `HomeRoute`; корневой ключ `stub-SCR-50` сохранён): строит содержимое через порт
  `customerHomeBodyProvider` и добавляет Android «Назад» ×2 для выхода (`home_back_to_exit`).
- `home_providers.dart` — порт `customerHomeBodyProvider` (`CustomerHomeArgs{view, sort}`).

Содержимое SCR-50 — `features/catalog/presentation/screens/customer_home_view.dart` (`CustomerHomeView`,
06 MOD-029): ребра `home → catalog` в DAG 06 §6.1 / `scripts/check_layers.py` нет (EQ-FEF-07, EQ-HOME-01).
Привязка — `app/router/shells/customer_mode_bindings.dart` (`customerModeOverrides` в `appOverrides`).

Тесты: `test/features/home/` (widget, навигация customer и guard, golden C/M/E — `golden/goldens/{ci,windows}`).
