# CHANGELOG — токены дизайн-системы (`contracts/design-tokens/tokens.json`)

Формат — по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/); версия — `meta.version` в `tokens.json`
(SemVer: мажор — переименование или удаление токена, минор — новые токены или новые значения, патч — уточнение
описаний и примечаний). Шаг 16 CI (`contracts-lint`) требует запись с новой версией при каждом изменении `tokens.json`.
Dart-классы `pos-app/lib/design_system/tokens/*.dart` генерируются `scripts/gen_tokens_dart.py` и руками не правятся.

## [1.4.0] — 2026-11-18 — пределы колонок «3 или 4, 5» (пакет own-server:GAP-APP)

Минорное изменение: `meta.version` 1.3.0 → 1.4.0, только новые значения существующих токенов. Основа — то же
указание владельца 2026-11-18 (дословно): «i pri zume ili na oborot setka tovarov doljna menyatsya 3 ili 4  5 i tak
alee no postav ogranicheniya»; вопрос итогового отчёта `.tmp/face/final-report.md` «Сетка на большом мониторе» решён
постановкой пакета own-server:GAP-APP: не больше 6 колонок ни в одном окне. Решение и записи в ТЗ (03 §7.3, 15
ADR-114, 02 AC-UI-10-035 и SCR-50.2, 12 T-CAT-038 и T-DS-104) — пакет документов. Ядро R0 не редактировалось.

### Изменено

- `breakpoint.expanded.productColumnsMax` 7 → 5, `breakpoint.large.productColumnsMax` 9 → 6; compact 3 и medium 4 —
  прежние. Колонки по классам окна: compact 2–3, medium 2–4 (3–4 с окна 732 lp у каталога сотрудника), expanded 4–5,
  large 6; минимум карточки (176, SCR-50 — 160) и нижний предел 2 — прежние: при узкой области (колонка категорий,
  крупный текст) колонок меньше нижней границы диапазона, карточки не уже минимума.
- Окна прототипа (ADR-114, T-UI-116): 1024 / 1280 — 4 / 5 (как прежде), 1366 / 1440 / 1536 — 5 (было 6 / 6 / 7),
  1920 — 6 (было 9). Карточка на 1920 у сотрудника ≈ 279 lp (не шире `gridCardMaxWidth` 280).
- Область товаров шире `gridMaxContentWidth(предел, gap)` теперь стоит по центру своей зоны (пустые полосы поровну
  слева и справа), а не у начала с пустой полосой справа (`CatalogProductView`; доклад генератора о
  `gridMaxContentWidth` обновлён). При пределе 6 полосы появляются у сотрудника с окна ≈ 1930 lp.

## [1.3.0] — 2026-11-18 — пределы сетки товаров (ADR-114, уточнение 2026-11-18)

Минорное изменение: `meta.version` 1.2.0 → 1.3.0, только новые токены и новое правило `DsBreakpoints.gridColumns`.
Указание владельца 2026-11-18 (чат, дословно): «i pri zume ili na oborot setka tovarov doljna menyatsya 3 ili 4  5 i
tak alee no postav ogranicheniya» (прочтение исполнителя: «и при зуме или наоборот сетка товаров должна меняться — 3
или 4, 5 и так далее, но поставь ограничения»). Решение — 15 ADR-114, уточнение 2026-11-18 (§5.8 (1)); правило — 03
§7.3 ред. 1.25. Значения прежних токенов не менялись. Ядро R0 не редактировалось.

### Добавлено

- `breakpoint.<класс>.productColumnsMax` — наибольшее число колонок сетки товаров в классе окна: compact 3, medium 4,
  expanded 7, large 9 (`DsBreakpoints.gridMaxColumnsFor(WindowClass)`). Значения — наибольшие числа колонок, которые
  прототип даёт в эталонных окнах класса (expanded — 1536 → 7, large — 1920 → 9; 15 ADR-114 AC (5)), и наибольшие
  колонки auto-fill от 176 на compact (до 599 lp) и medium (до 1023 lp): окна до 1920 включительно не меняются.
- `layout.gridCardMaxWidth` 280 — наибольшая ширина карточки сетки товаров (`DsBreakpoints.gridCardMaxWidth`): шире
  предела колонок × 280 + зазоры область товаров не растягивается (`DsBreakpoints.gridMaxContentWidth(columns, gap)`),
  остаток справа пустой. 280 ≥ карточки auto-fill при двух колонках ((3 × 176 + 16) / 2 = 272), поэтому предел
  ширины действует только после предела колонок.
- Инварианты генератора: `productColumnsMax` ≥ `gridMinColumns` и не убывает от compact к large;
  `gridCardMaxWidth` ≥ (3 × max(`cardMinWidth`, `catalogCardMinWidth`) + наибольший зазор сетки) / 2.

### Изменено

- `DsBreakpoints.gridColumns(width, gap, {required WindowClass windowClass, minCardWidth = cardMinWidth, int?
  maxColumns})`: auto-fill от `minCardWidth`, не меньше `gridMinColumns` и не больше `gridColumnsCap(windowClass,
  maxColumns:)` — предела класса окна и, если задан, своего предела экрана (SCR-50 — `gridMaxColumns` 6). Прежняя
  форма `maxColumns: null` («без верхнего предела», каталог сотрудника ADR-114) снята: у всех сеток товаров теперь
  есть предел класса окна. `gridMaxColumns` 6 остаётся пределом SCR-50 (схема — описание поля).


Минорное изменение: `meta.version` 1.1.0 → 1.2.0, только новые токены. Указание владельца 2026-10-31: «сделай
точь-в-точь, даже цвета». Решение — ADR-114 (15), вопросы — Q-338 (14); решение владельца 1 — цвета прототипа точно,
4 пары ниже нормы контраста записываются как отклонение, AA-оттенки остаются в `alternatives`. Палитра B (`color`,
ADR-111), шкалы `text.styles`, `space`, `radius` xs…full, `elevation` 0…3, `layout`, `density`, `motion` не менялись.
Ядро R0 не редактировалось.

### Добавлено

- `componentColor` (новая группа, 22 токена, поля `DsColors` после палитры): `catalogName` #16206A, `catalogMeta`
  #6B7487, `catalogMetaOnPage` #6B7487, `searchPlaceholder` #757575, `stockIn` #177245, `stockLowText` #8A5300,
  `stockLowIcon` #B26A00, `stockOutText` #5F6878, `stockOutIcon` #8A93A3, `photoPlaceholderBg` #F4F7FB,
  `photoPlaceholderIcon` #9AA3B2, `photoPlaceholderText` #7D879A, `ribbonPlaceholderBg` #EEF3FA, `ribbonGlyph` #7D879A,
  `rowDivider` #EEF2F8, `segmentIdleText` #3D4761, `neutralButtonBorder` #D5DEEA, `drawerFooterBg` #FBFCFE, `link`
  #1F5FA8, `favoriteOutline` #E2A93B, `toastBg` #0E1456, `toastCheck` #2FB36A. От палитры не зависят: те же значения
  входят в `DsColors.lightB`, `lightB20261021` (и `lightA`).
- `alternatives.AA_2026_10_31` (`status: aa-variant`): палитра B с AA-оттенками 4 исключений — `catalogMetaOnPage`
  #687184 (4.51), `searchPlaceholder` #6D6D6D (4.55), `photoPlaceholderText` #6A7282 (4.50), `favoriteOutline` #BC8D31
  (3.00). Генератор всегда выводит `DsColors.lightAA20261031`; включить — `AppTheme.light(colors: DsColors.lightAA20261031)`.
- `text.component` (22 стиля, поля `DsTypography`): `catalogTitle` 30/800 −0.4, `brandWordmark` 21/700 −0.2,
  `drawerTitle` 20/800, `columnTitle` 19/700, `catalogPrice` 18/800 −0.2, `totalLabel` 18/800, `cartTotal` 24/800,
  `listPrice` 17/800, `lineSum` 15/800, `compactPrice` 14/800, `avatarInitial` 15/700, `listName` 15/600, `cardName`
  14/600 (1.32), `chip` 14/600, `sortLabel` 14/500, `ribbonLabel` 13/500 (выбранная 700, 1.2), `meta` 13/400, `stock`
  12.5/500, `tileLabel` 12/600 (выбранная 700, 1.2), `sku` 12/400, `cartBadge` 11/700 (строка 18), `bellBadge` 10/700
  (строка 17). Межстрочный множитель 1.21 (CSS `line-height: normal` у Inter), если не указан другой; цифры
  пропорциональные, как в прототипе (`tabularFigures: false`). Геттеры `ribbonLabelSelected`, `tileLabelSelected`.
  Высота строки в lp (`lineHeight`) там, где движок Flutter округлил бы 1.21 не так, как Chrome (ревью RV-15):
  `catalogPrice` и `totalLabel` 21, `listPrice` 20, `lineSum`, `avatarInitial` и `listName` 19 — по правилу Chrome
  «восхождение и нисхождение hhea, каждое округлено до пикселя» (Flutter: 18 × 1.21 → 22, 17 → 21, 15 → 18).
- `radius`: `segment` 7, `badge` 9, `control` 10, `catalogCard` 14 (имя `card` занято геттером `DsRadii.card` из 03 §17.4),
  `star` 17, `arrow` 19, `avatar` 19, `circle` 28 — без кратности 4 lp.
- `elevation`: `cardHover` 0 6 18 rgba(14,20,86,.10), `ribbonArrow` 0 4 12 .14, `drawer` −12 0 40 .18 (scrim
  `overlay`), `toast` 0 10 30 .30 — поля `DsElevation` с теми же именами; новое поле уровня `baseColor` (`textPrimary`):
  генератор проверяет, что rgb тени равен этому цвету палитры. `e0…e3` не менялись (rgba(27,31,42), ядро §8.3).
- `catalog` (новая группа) → класс `DsCatalogMetrics` в `ds_breakpoints.dart`: колонка 132 (поля 20/14/24/18), плитка
  min 88, поля 10/6/8, картинка 46×40, зазор 10; карточка ленты 118×148, зазор 10, поле 2, шаг стрелки 3 карточки;
  поля контента 18/24/40/8; сетка min 176, зазор 14, высота 340 (360 при переносе цены); строка инструментов 42, чип 40,
  кнопка сегмента 32. Инварианты: `columnMinWidth` = `layout.catalogColumn`, `gridMinCard` = `layout.catalogCardMinWidth`.
- `DsBreakpoints.gridColumns(width, gap, {minCardWidth, int? maxColumns = gridMaxColumns})`: `null` — без верхнего
  предела (каталог сотрудника: 9/6/5/4 колонок при W 1744/1264/1104/848, зазор 14). Остальные экраны — до 6, как раньше.
- Пары контраста CP-091…CP-133 (43 пары; всего 133): `allowed` — 27, `exception` — 5, `decorative` — 9, `forbidden` — 2.
  CP-124…CP-133 (ревью RC-07) — фоны hover и pressed строк компакт-таблицы и строк compact: `catalogMeta` на
  `surfaceHover` 4.45 и на `surfacePressed` 4.13 — `forbidden` (подписи этих строк — `textSecondary`, карточки сетки и
  списка при нажатии фон не меняют), название и наличие при нажатии — `allowed`, круг с крестом «Нет в наличии» —
  `decorative` (рядом текст). Исключения:
  4 пары ADR-114 (`decision: "ADR-114"`) — CP-096 «Найдено» 4.32, CP-097 плейсхолдер поиска 4.05, CP-106 «Фото появится
  из 1С» 3.37, CP-120 контур звезды 2.11; CP-095 — текст отключённой кнопки «Нет в наличии» 4.14 (исключение WCAG
  1.4.3 для неактивных элементов, как CP-062). Примечания CP-084…CP-086 ссылаются на новые пары.
- Схема: группы `componentColor`, `catalog`, `text.component`, `alternatives.AA_2026_10_31`, новые ключи `radius` и
  `elevation`, поле `baseColor`, поле пары `decision` (`const` "ADR-114"); пары могут называть компонентные цвета.

### Изменено

- `scripts/check_contrast.py`: компонентные цвета в расчёте; явный перечень исключений в коде — `WCAG_EXCEPTIONS`
  (CP-062, CP-079, CP-095) и `ADR114_EXCEPTIONS` (CP-096, CP-097, CP-106, CP-120). Пара со статусом `exception` вне
  перечня — ошибка; пара ADR-114 без статуса `exception` и `decision`, отсутствующая или уже проходящая порог — ошибка;
  `decision` у другой пары — ошибка; `alternatives.AA_2026_10_31` должна заменять ровно 4 цвета исключений, и с ней все
  `allowed` и 4 исключения обязаны проходить порог.
- `scripts/gen_tokens_dart.py`: вывод групп выше; длинные doc-комментарии переносятся по словам до 120 символов;
  инварианты `baseColor`, `catalog`↔`layout`, имена стилей и компонентных цветов без пересечений.
- `pos-app/pubspec.yaml`: семейство Inter, weight 800 — `assets/fonts/Inter/Inter-ExtraBold.ttf`, статический экземпляр
  из лежащего в репозитории `Inter-Variable.ttf` (fontTools 4.60.0, wght=800, opsz=14; команда и sha256 —
  `assets/fonts/Inter/SOURCE.txt`).

## [1.1.0] — 2026-10-29 — палитра по утверждённому прототипу (ADR-111)

Минорное изменение: `meta.version` 1.0.0 → 1.1.0. Решение — ADR-111 (15), одобрение пользователя 2026-10-29;
вопрос заказчику о подтверждении цветов — Q-333 (14). Ядро R0 не редактировалось.

### Изменено

- Палитра B (`color`, `DsColors.lightB`) — значения по прототипу `docs/specification/visual/prototype/Main.dc.html`:
  `background` #F1F6FC, `surfaceVariant` #EAF1FB, `primary` #D9380F (hover #BF300B, pressed #A82A09),
  `onPrimary` #FFFFFF (4.64:1, AA), `primaryText` #C9330C, `primaryContainer` #FDEEE9, `textPrimary` #0E1456,
  `textTertiary` #656E80, `border` #E3E9F2, `success` #177245, `warning` #8A5300, `error` #D21B1F,
  `errorContainer` #FDEAEA, `favorite` #E2A93B, `overlay` rgba(14,20,86,0.28) и др. (полная таблица — 03 §5.3).
  Без изменений: `surface`, `successContainer`, `warningContainer`, `info`, `infoContainer`, `focus`, `disabledText`,
  `brandAccent` #FF8700 (логотип).
- `meta.paletteName` — «Оранжевый (прототип 2026-10-29)»; `meta.palette` остаётся «B».
- `contrast.pairs`: `documented` пересчитаны у всех пар (CP-033 и CP-080 получили значения вместо `null`); статусы
  CP-022, CP-024 (`textTertiary` на `background` и `surfaceHover`) и CP-032…CP-034 (белый на `primary`,
  `primaryHover`, `primaryPressed`) → `allowed`; примечания CP-026…CP-028, CP-065…CP-067, CP-078.
- `scripts/check_contrast.py`: правило «белый на primary обязан быть forbidden» заменено — пара обязательна, статус
  `allowed` тогда и только тогда, когда контраст ≥ 4.5; `forbidden`-пара с белым текстом, проходящая порог, — ошибка;
  обязательна CP-087 (белый на `brandAccent`) со статусом `forbidden`.

### Добавлено

- Цвета (DS-002, [НОВОЕ ИМЯ] в 03 §5.3): `primaryContainerBorder` #F5C6B6 — декоративная рамка тинта (1.54:1 к белому);
  `onPrimaryContainer` #A82A09 — текст и иконки на тинте (6.19:1 на #FDEEE9, 6.01:1 на #FCEAE4). В альтернативах —
  `border` и `primaryText` соответствующего набора.
- Layout: `topBarHeight` 68, `navDrawer` 320, `cartDrawer` 420, `catalogColumn` 132, `catalogCardMinWidth` 176
  (`DsBreakpoints.*`); `DsBreakpoints.gridColumns(width, gap, {minCardWidth = cardMinWidth})`. Прежние `sidebar*`,
  `rail`, `cartNarrow`, `cartWide`, `cardMinWidth` 160 сохранены (SCR-40, SCR-50, customer).
- Пары контраста CP-084…CP-090: `textTertiary` на `surfaceVariant` 4.51 и на `disabledBg` 4.53; `favorite` на
  `surface` 2.11 (`forbidden`, звезда только с контуром `warning`); белый на `brandAccent` 2.41 (`forbidden`);
  `onPrimaryContainer` на `primaryContainer` 6.19 и на `primaryContainerPressed` 6.01; рамка `primaryContainerBorder`
  на `surface` 1.54 (`decorative`).
- Откат: `alternatives.B_2026_10_21` (`status: rollback`) — прежний блок `color` целиком; генератор всегда выводит
  `DsColors.lightB20261021`, вернуть — `AppTheme.light(colors: DsColors.lightB20261021)`.

## [1.0.0] — 2026-10-21 — первая версия (RM-B-006)

Палитра B «Оранжевый» (ядро v1.9 §24.1), альтернатива A для справки, шкалы текста, отступов, радиусов, теней,
брейкпоинтов, плотности и анимаций, 83 пары контраста CP-001…CP-083.
