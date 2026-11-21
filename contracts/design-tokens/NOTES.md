# Токены дизайн-системы: заметки (RM-B-006)

Задача RM-B-006 из `docs/specification/13_IMPLEMENTATION_ROADMAP.md` §3.2. Токены хранятся в одном файле, из него генерируется Dart-код и проверяется контраст.

**Источники.** `03_UX_UI_DESIGN_SYSTEM.md`:

- §5.3 — палитра B;
- §5.2 — палитра A, только для справки;
- §5.4.2, §5.4.3, §5.4.5, §5.8, §5.9 — контраст и роли цветов;
- §6.2 — шрифты и размеры текста;
- §7.0–§7.6 — отступы, радиусы, тени, брейкпоинты;
- §8.1 — плотность;
- §11.1 — анимации;
- §17.1–§17.5 — сигнатуры Dart.

Ядро R0 v1.9: §8, §17.5, §18.2 п. 15, §24.1. По §18.1 ядра словарь дизайна ведёт документ 03.

**Версия 1.1.0 (2026-10-29, ADR-111).** Значения палитры B взяты из утверждённого прототипа
`docs/specification/visual/prototype/Main.dc.html` (одобрение пользователя 2026-10-29). Это отклонение от HEX ядра §24.1;
ядро не редактируется, отклонение записано в ADR-111, подтверждение заказчика — Q-333. Прежние значения —
`alternatives.B_2026_10_21` (откат). История версий — `CHANGELOG.md`.

**Версия 1.2.0 (2026-10-31, ADR-114).** Владелец: «сделай точь-в-точь, даже цвета». Значения прототипа переносятся
без округления до шкал для экрана выбора товаров SCR-10/11/12, шапки сотрудника и drawer корзины (`componentColor`,
`text.component`, радиусы `segment`…`circle`, тени `cardHover`…`toast`, группа `catalog`). Источник значений —
вычисленные стили прототипа (`.tmp/redesign2/design/design-spec.md`, план `plan.json` → appChanges[0]). Решение
владельца 1: цвета точно; 4 пары ниже нормы контраста — отклонение от A11Y-002 / NFR-A11Y-001 в ADR-114, их AA-оттенки
— `alternatives.AA_2026_10_31` (§3 п. 14). Палитра B и прежние шкалы не менялись.

## 1. Состав

| Файл | Что это |
|---|---|
| `tokens.json` | Источник истины. Основная палитра — B «Оранжевый» в значениях ADR-111. В `alternatives.A` — палитра A только для справки; в `alternatives.B_2026_10_21` — прежняя палитра B для отката (`status: rollback`); в `alternatives.AA_2026_10_31` — AA-оттенки исключений ADR-114 (`status: aa-variant`). С 1.2.0 — компонентные токены прототипа (`componentColor`, `text.component`, `catalog`, новые ключи `radius` и `elevation`). Пары для проверки контраста — в `contrast.pairs` |
| `tokens.schema.json` | JSON Schema (draft 2020-12). Проверяет все 41 цвет (с 1.1.0 — плюс `primaryContainerBorder`, `onPrimaryContainer`), 22 компонентных цвета (1.2.0), три альтернативы, кратность размеров 4 lp у шкал (у размеров прототипа — целые без кратности), перечни и формат пар контраста |
| `CHANGELOG.md` | Журнал версий `meta.version` (шаг 16 CI) |
| `../../scripts/gen_tokens_dart.py` | Генератор Dart-классов. Перед генерацией проверяет файл по схеме и инварианты (§3). Каталог вывода передаётся аргументом |
| `../../scripts/check_contrast.py` | Проверка контраста по WCAG 2.x для пар из `contrast.pairs` |

Пространства имён в `tokens.json` повторяют `ds.<группа>.<имя>`:

- `color` → `ds.color.*`;
- `text` → `ds.text.*`;
- `space` → `ds.space.1…10`;
- `radius` → `ds.radius.{xs,sm,md,lg,xl,full}`;
- `elevation` → `ds.elevation.{0..3}`;
- `breakpoint` → `ds.breakpoint.*`;
- `motion.duration` → `ds.motion.*`;
- `motion.curve` → `ds.motion.curve.*`;
- `density` → `DsDensity`.

В `layout` лежат размеры раскладки из 03 §7.3, §8.4 и §17.4: сайдбар, корзина, rail, `cardMinWidth`, `contentMaxLarge`. С 1.1.0 (ADR-111) — размеры прототипа: `topBarHeight` 68, `navDrawer` 320, `cartDrawer` 420, `catalogColumn` 132, `catalogCardMinWidth` 176; прежние ключи сохранены (SCR-40, SCR-50, customer).

С 1.2.0 (ADR-114) добавлены группы прототипа:

- `componentColor` → поля `DsColors` после палитры (`DsColors.lightB.catalogName` и т. д.); каждое значение — `{value, use}`;
- `text.component` → поля `DsTypography` (`catalogTitle`, `catalogPrice` …) и геттеры `*Selected`;
- `radius.segment` … `radius.circle` → поля `DsRadii`;
- `elevation.cardHover` … `elevation.toast` → поля `DsElevation`;
- `catalog` → класс `DsCatalogMetrics` (статические константы `double`, `int`, `EdgeInsets`, `Size`) в `ds_breakpoints.dart`.

## 2. Команды

```
python -I -X utf8 -c "import json,jsonschema; s=json.load(open('contracts/design-tokens/tokens.schema.json',encoding='utf-8')); jsonschema.Draft202012Validator.check_schema(s); e=list(jsonschema.Draft202012Validator(s).iter_errors(json.load(open('contracts/design-tokens/tokens.json',encoding='utf-8')))); print(len(e)); raise SystemExit(1 if e else 0)"
python -I -X utf8 scripts/gen_tokens_dart.py <OUT_DIR>            # этап C: pos-app/lib/design_system/tokens
python -I -X utf8 scripts/gen_tokens_dart.py <OUT_DIR> --check    # проверка дрейфа: код 1, если файлы отличаются
python -I -X utf8 scripts/check_contrast.py                        # код 1 при нарушении, расхождении или ошибке
```

Коды выхода генератора: 0 — успех; 1 — `--check` нашёл различия; 2 — вход не прошёл схему или инварианты.

## 3. Решения, принятые при неоднозначностях

1. **Палитра A в `tokens.json`.** В 13 §3.2 (RM-B-006) сказано, что A+ «в `tokens.json` не вносится». Задача этапа B требует хранить A в `alternatives.A` для справки. При этом 03 §17.2 и §5.9 п. 8 описывают `DsColors.lightA` как способ вернуться к A+.
   - Решение: A хранится в `alternatives.A` со статусом `historical-reference`.
   - Генератор по умолчанию её не использует: выводит `DsColors.lightB`, `DsColors.light = lightB` и откат `lightB20261021` (см. ниже).
   - `DsColors.lightA` выводится только с флагом `--with-alternative-a`. Нужен ли этот флаг, решает RM-C-003.
   - **`alternatives.B_2026_10_21` (ADR-111)** — прежний блок `color` палитры B (редакция 2026-10-21) со статусом
     `rollback`. Новые ключи в нём: `primaryContainerBorder` = `border`, `onPrimaryContainer` = `primaryText` этого набора
     (то же правило — в `alternatives.A`). Схема требует обе альтернативы; генератор проверяет набор ключей у всех
     альтернатив и **всегда, без флага**, выводит `DsColors.lightB20261021` (имя в lowerCamelCase — линт
     `constant_identifier_names`), иначе `make gen` и `--check` расходились бы. Откат —
     `AppTheme.light(colors: DsColors.lightB20261021)`.
   - **B-AR-15 (minor, архитектурная проверка этапа B):** отклонение от буквы RM-B-006 вынесено на ворота G-B2 —
     правок нет. Причина не удалять `alternatives.A` в этой задаче: постановка этапа B прямо требовала хранить A для
     справки, а 03 §17.2 и §5.9 п. 8 (владелец дизайна, ядро §18.1) описывают `DsColors.lightA` как путь возврата к A+;
     удаление противоречило бы 03, оставление — формулировке 13. Решение на G-B2: (а) принять отклонение и поправить
     формулировку RM-B-006 в 13, либо (б) удалить `alternatives` из `tokens.json` и `tokens.schema.json` и флаг
     `--with-alternative-a` из генератора (палитра A остаётся только в 03 §5.2). На вывод по умолчанию (палитра B)
     это не влияет: `gen_tokens_dart.py` без флага A не выводит.
2. **Цвет с прозрачностью.** `overlay` и цвета теней хранятся как `{ "rgb": "#1B1F2A", "opacity": 0.48 }`. В Dart это `Color.fromRGBO(27, 31, 42, 0.48)` — точное значение из 03, без округления альфы до 8 бит. Остальные цвета записаны как `#RRGGBB` в верхнем регистре, в Dart — `Color(0xFFRRGGBB)`.
3. **Детерминизм.**
   - Поля `DsColors` идут в алфавитном порядке ключей.
   - Порядок шкал (текст, радиусы, тени, брейкпоинты, анимации, плотность) задан константами в генераторе и не зависит от порядка ключей в JSON.
   - В заголовке файла стоит sha256 канонического JSON (`sort_keys`, без пробелов), поэтому он не зависит от форматирования и переводов строк в `tokens.json`.
   - Файлы пишутся в UTF-8 с LF.
   - Временных меток в выводе нет.
4. **Имена статических экземпляров.** В 03 §17.4–§17.5 не названы готовые экземпляры для `DsSpacing`, `DsRadii`, `DsElevation`, `DsMotion`. Генератор называет их единообразно — `defaults`. Имена из 03 сохранены: `DsColors.lightB` и `light`, `DsTypography.inter`.
5. **`pagePadding*`.** 03 §17.4 требует геттеры `pagePaddingCompact/Medium/Large` (16/24/32). Это «боковые поля» из 03 §7.2, поэтому они реализованы как `EdgeInsets.symmetric(horizontal: …)`. Для `expanded` боковое поле 24 — то же, что `pagePaddingMedium`.
6. **`DsBreakpoints`.**
   - Добавлен чистый помощник `forWidth(double)`. Через него работает `of(context)` по `MediaQuery.sizeOf`, и его удобно тестировать.
   - `gridColumns` реализует формулу 03 §7.3: `max(2, min(6, floor((W+gap)/(160+gap))))`. С 1.3.0 (ADR-114, уточнение
     2026-11-18): `max(2, min(предел, floor((W+gap)/(minCardWidth+gap))))`, где предел — `gridColumnsCap(windowClass,
     maxColumns:)`: `breakpoint.*.productColumnsMax` класса окна (3 / 4 / 5 / 6 с 1.4.0; в 1.3.0 — 3 / 4 / 7 / 9) и,
     если задан, предел экрана (SCR-50 — 6); шире `gridMaxContentWidth(предел, gap)` (карточки по `gridCardMaxWidth`
     280) область товаров не растягивается и с 1.4.0 стоит по центру своей зоны — это делает вызывающий код
     (`CatalogProductView`).
   - Ограничение W ≤ 1200 на `large` применяет вызывающий код: так записано в 03 §7.3 «W — ширина контентной зоны».
   - Все 14 контрольных значений таблицы 03 §7.3 проверены smoke-тестом (§5).
7. **`DsDensityValues.gridGap`.** Зазор сетки 16/12 взят из 03 §7.3, где он привязан к плотности. Добавлен рядом с полями 03 §17.4. `forWindowClass` строится из `density.*.windowClasses`. Инвариант генератора: каждый класс окна принадлежит ровно одной плотности.
8. **`DsMotion`.**
   - Кривые: `Cubic` по 03 §11.1; `emphasized` = emphasizedDecelerate `(0.05, 0.7, 0.1, 1)`.
   - `reducedCrossfade` = 80 мс. Схема не допускает значение больше 80 (ядро §17.5).
   - `resolve()` учитывает три источника: `MediaQuery.disableAnimationsOf`, `platformDispatcher.accessibilityFeatures.reduceMotion` и настройку SCR-42 (параметр `userReduceMotion`).
   - `lerp` дискретный: при t < 0.5 берётся текущее значение, иначе другое.
9. **`DsElevation`.**
   - В сигнатуре 03 §17.4 есть только `e0…e3` и `overlay`.
   - Граница `border 1 px` у уровней 0–1 и затемнение `overlay` у уровня 3 (03 §7.6) хранятся в `tokens.json` (`borderColor`, `borderWidth`, `scrim`). В Dart они попадают только в комментарии. Рисуют их компоненты.
   - `overlay` берётся из токена цвета, на который указывает `scrim`.
10. **`breakpoint.*.columns` и `columnGap`** (03 §7.2) хранятся в токенах, но в Dart не выводятся: в 03 §17.4 нет для них сигнатуры. Они пригодятся для CSS и документации.
11. **Типографика.**
    - `TextStyle` задаётся без цвета: цвет ставит компонент.
    - `height` = lineHeight / fontSize.
    - Запасные системные шрифты из 03 §6.1 не выводятся: golden-тесты идут только с Inter.
    - `contrastClass` — справочная колонка «порог контраста» из 03 §6.2.
    - Геттеры `*Medium` создаются для стилей, у которых есть `fontWeightMedium` (`bodyLg`, `body`, `caption`), как в 03 §17.3.
12. **Пары контраста** (`contrast.pairs`, с 1.2.0 — 133 пары, ID `CP-001…CP-133`, новые CP-091…CP-133 — ADR-114, п. 14; CP-124…CP-133 — фоны hover и pressed строк каталога, ревью RC-07; в 1.1.0 — 90; до 1.1.0 — 83). Взяты из 03 §5.4.2 (B), строк B в §5.4.3, §5.4.5 и правил §5.3, §5.8; CP-084…CP-090 — ADR-111. Повторяющиеся строки разных таблиц сведены в одну пару; в поле `source` указаны все разделы. Статусы:
    - `allowed` — проверяется порогом: `text` 4.5, `large-text` 3.0, `non-text` 3.0. С 1.1.0 сюда перешли белый на `primary` / `primaryHover` / `primaryPressed` (CP-032…CP-034: 4.64 / 5.76 / 7.00) и `textTertiary` на `background` / `surfaceHover` (CP-022, CP-024);
    - `forbidden` — запрещённое сочетание, нарушением не считается. Так помечены: `primary` как текст (CP-026…CP-028: #D9380F проходит AA только на `surface`); `primary` как единственный индикатор (CP-065…CP-067 — 3:1 теперь проходит, запрет остаётся правилом ролей DS-098); `primaryText` как текст на `iconButtonPressed`; `favorite` без контура (CP-086); белый на `brandAccent` (CP-087);
    - `exception` — `disabledText`/`disabledBg`, логотип `brandAccent`;
    - `decorative` — `border`, скелетон, hover и pressed поверхности, контур чекбокса к своей заливке, рамка тинта `primaryContainerBorder` (CP-090);
    - `reference` — справочно: белый на `info`/`warning` (в R1 не применяется) и `focus` к `primary` (кольцо рисуется с отступом).

    Неоднозначные строки разделены на две пары:
    - `textTertiary` на `background` и на `surfaceHover`: обычный и крупный текст — отдельные пары (с 1.1.0 обе `allowed`);
    - `primaryText` на `iconButtonPressed`: текст — `forbidden`, иконка — `allowed` `non-text`.

    С 1.1.0 `documented` заполнено у всех 90 пар (у CP-033 и CP-080 раньше был `null`) и совпадает с расчётом до 0.005.
    Узкие запасы: CP-029/032 4.643, CP-078 3.0055 (поэтому `documented` 3.01, не 3.00), CP-084 4.51, CP-085 4.53,
    CP-040 4.55 — любая правка этих HEX требует пересчёта.
13. **Обязательная проверка политики (ADR-111).** `check_contrast.py`:
    - пара «#FFFFFF на primary» (`text`) обязательна, её статус `allowed` тогда и только тогда, когда контраст ≥ 4.5 (иначе `forbidden`);
    - `forbidden`-пара с белым текстом (`text`/`large-text`), проходящая свой порог, — ошибка «обновите статус по ADR-111»;
    - CP-087 «#FFFFFF на brandAccent» (`text`) обязательна со статусом `forbidden`: запрет белого действует для оранжевых заливок ниже 4.5:1.

    Нарушение любого пункта — код выхода 1. Тот же инвариант «allowed ⇔ ≥ 4.5» проверяет `pos-app/test/design_system/tokens_test.dart`.
14. **Компонентные токены прототипа (1.2.0, ADR-114).**
    - **Компонентные цвета отдельно от палитры.** `componentColor` — не часть `color`: иначе `alternatives.A` и
      `B_2026_10_21` пришлось бы дополнять выдуманными историческими значениями. Генератор добавляет те же значения во
      все константы `DsColors` (`lightB`, `lightB20261021`, `lightA`); набор `aa-variant` заменяет только свои ключи.
      Имена не пересекаются с палитрой (инвариант генератора и `check_contrast.py`). Пары контраста называют их так же,
      как цвета палитры.
    - **Решение владельца 1 — «точно».** Четыре пары ниже нормы — исключения ADR-114 со статусом `exception` и полем
      `decision: "ADR-114"`: CP-096 `catalogMetaOnPage` на `background` 4.32, CP-097 `searchPlaceholder` на
      `surfaceVariant` 4.05, CP-106 `photoPlaceholderText` на `photoPlaceholderBg` 3.37, CP-120 `favoriteOutline` на
      `surface` 2.11 (non-text). Перечень зашит в `check_contrast.py` (`ADR114_EXCEPTIONS`) и в `tokens_test.dart`:
      правка одного `tokens.json` не может добавить исключение. Исключения самой WCAG — `WCAG_EXCEPTIONS`: CP-062
      (неактивный элемент), CP-079 (логотип) и CP-095 — текст отключённой кнопки «Нет в наличии» `catalogMeta` на
      `disabledBg` 4.14 (WCAG 1.4.3 не требует контраста у неактивных элементов; это не отклонение A11Y-002, но ADR-114
      должен его назвать). Любая другая пара `exception` — ошибка.
    - **AA-оттенки** — `alternatives.AA_2026_10_31`: #687184, #6D6D6D, #6A7282, #BC8D31 (4.51 / 4.55 / 4.50 / 3.00 —
      запас минимальный, любая правка требует пересчёта). Включаются одной строкой:
      `AppTheme.light(colors: DsColors.lightAA20261031)`. `check_contrast.py` требует, чтобы набор заменял ровно 4 цвета
      исключений и чтобы с ним проходили все `allowed` и все 4 исключения.
    - **Декоративные пары 1.2.0**: значок-картинка заглушки фото #9AA3B2 на #F4F7FB (2.37 — смысл передаёт текст),
      белая галочка в круге тоста (2.70 — смысл передаёт текст тоста), плашки, разделители, рамка «Отложить».
    - **Текст.** Межстрочный множитель 1.21 = CSS `line-height: normal` у Inter (hhea (1984 + 494) / 2048 = 1.2100);
      у бейджей — высота строки в lp (18, 17) через `lineHeight`. Движок Flutter округляет высоту строки до целого
      (18 × 1.21 → 22, 17 → 21, 15 → 18), а Chrome округляет отдельно восхождение и нисхождение (21, 20, 19), поэтому
      у `catalogPrice`, `totalLabel` (21), `listPrice` (20), `lineSum`, `avatarInitial`, `listName` (19) тоже задан
      `lineHeight` (ревью RV-15); у остальных стилей 1.21 даёт ту же строку, что Chrome. Дробные строки CSS 1.2
      (`tileLabel` 14.4, `ribbonLabel` 15.6) движок округляет до 14 и 16 — точнее не задать. Цифры пропорциональные (`tabularFigures: false`):
      в прототипе нет `font-variant-numeric`, а правило 03 §6.1 (tnum у цен) для этих стилей отступает по ADR-114.
      `bellBadge` 10 lp — ниже минимума A11Y-008 (11 lp у цифр бейджей); схема допускает 10 только для стилей
      `text.component`, отклонение должен назвать ADR-114.
    - **Радиус 14** называется `catalogCard`: имя `card` занято геттером `BorderRadius get card` (= `md`) из 03 §17.4.
    - **Тени.** Компонентные тени — на основе `textPrimary` #0E1456 (поле `baseColor`, генератор сверяет rgb с палитрой).
      `e0…e3` оставлены со значениями ядра §8.3 (rgba(27,31,42)) — их используют другие экраны; ADR-114 касается только
      экрана выбора товаров, шапки и drawer корзины. `blurRadius` Flutter = blur CSS, как у `e1…e3`; разницу
      гауссова размытия Chrome и Flutter оценивает сверка снимков (WP-QA).
    - **`DsCatalogMetrics`** лежит в `ds_breakpoints.dart` (новый файл не нужен; генератор выводит 8 файлов, как и
      раньше). `gridColumns(..., maxColumns: null)` снимает верхний предел 6 только для каталога сотрудника (до 1.3.0; с
      1.3.0 у каждой сетки товаров — предел класса окна, `maxColumns` — только свой предел экрана).
    - **Inter 800.** `Inter-ExtraBold.ttf` — статический экземпляр из `pos-app/assets/fonts/Inter/Inter-Variable.ttf`
      (fontTools 4.60.0, wght=800, opsz=14, `SOURCE_DATE_EPOCH` = метка исходного файла — сборка воспроизводима, sha256 в
      `SOURCE.txt`). Подключён в `pubspec.yaml` весом 800 и в `ds_test_support.dart`.
    - **CSS веб-демо.** `demo/web/site-src/build-site.mjs` строит `demo-tokens.css` из `tokens.json`; новые группы он
      читает частично (радиусы и тени — да, `componentColor`, `text.component`, `catalog` — нет). Структура
      `elevation.*.shadows[].color.rgb` сохранена, чтобы сборщик не сломался.

## 4. Ограничения и что передаётся дальше

- **Форматирование (с 2026-10-29).** Генератор сам пишет файлы в том виде, какой даёт `dart format` (tall style Dart ≥ 3.7, ширина 120 из `pos-app/analysis_options.yaml`). Раскладку считает сам скрипт, без Dart SDK, поэтому вывод не зависит от машины и остаётся детерминированным. Правила, которых достаточно для генерируемых конструкций:
  - список в скобках (параметры, аргументы, литерал списка) пишется в одну строку, если она помещается в 120 символов; иначе каждый элемент — на своей строке с завершающей запятой; вложенный список решает так же на своей строке;
  - между документированными членами класса — пустая строка;
  - `switch`-выражение всегда разбито по веткам;
  - палитры `DsColors` всегда разбиты: у каждого значения есть комментарий `// HEX`.

  Поэтому `dart format` по `pos-app` не меняет `lib/design_system/tokens/*.dart`, а `gen_tokens_dart.py … --check` остаётся с 0 различий. До этого генератор писал неформатированный код: кто-нибудь запускал `dart format` по `pos-app`, и `--check` падал (так было на HEAD и после переноса прототипа). Проверено на 10 вариантах `tokens.json` (межбуквенные интервалы, тени, отступы, радиусы, а также случаи, где строка ровно помещается или не помещается): у каждого вывод генератора совпадает с самим собой после `dart format --page-width 120` (Dart 3.10.7). Если новая версия SDK начнёт форматировать иначе, это сразу покажет `--check` после `dart format`; тогда правило правится в разделе `dart format layout` скрипта.
- **Переводы строк.** Генерируемые файлы — LF. Если в репозитории включён `core.autocrlf`, для `pos-app/lib/design_system/tokens/*.dart` нужен `.gitattributes` с `eol=lf`. В этой задаче он не создавался: путь вне назначенных.
- **CSS-переменные** `--ds-color-*` для `docs/specification/visual/*.html` (13 §5.1, строка «Дизайн-токены») не генерируются: это вне путей RM-B-006.
- **`tokens_test.dart`** (JSON ↔ Dart, RM-C-003) и Dart-эквивалент `contrast.py` (T-DS-001…012) — этап C. Список пар для них уже есть в `contrast.pairs`.

## 5. Результаты проверок

### 5.0. Версия 1.2.0 (2026-10-31, ADR-114)

| Проверка | Результат |
|---|---|
| Схема по мета-схеме 2020-12; `tokens.json` по схеме | 0 ошибок |
| `gen_tokens_dart.py` дважды во временные каталоги + `diff -r` | пустой вывод |
| `gen_tokens_dart.py pos-app/lib/design_system/tokens --check` | «checked 8 files, 0 differ», код 0 |
| Вывод генератора после `dart format --page-width 120` (Dart 3.10.7) | «Formatted 8 files (0 changed)» |
| `check_contrast.py` | 133 пары: PASS 97, FORBIDDEN 11, DECOR 15, EXCEPTION 7 (из них ADR-114 — 4), REFERENCE 3; нарушений 0, расхождений 0, ошибок 0; AA-набор: 4 из 4 PASS; `RESULT: OK` (ревью RC-07, RV-15) |
| Отрицательные тесты `check_contrast.py` (копии) | CP-096 `allowed` → 1; лишний `exception` (CP-093) → 1; без CP-120 → 1; AA-оттенок ниже порога → 1; AA заменяет лишний цвет → 1; `decision` у чужой пары → 1; исключение уже проходит порог → 1; без `AA_2026_10_31` → 1 |
| Отрицательные тесты генератора | rgb тени ≠ `baseColor` → 2; `catalog.gridMinCard` ≠ `layout.catalogCardMinWidth` → 2; стиль с именем члена (`priceOf`) → 2; компонентный цвет с именем палитры → 2 (схема) |
| `flutter analyze` (pos-app) | No issues found |
| `flutter test test/design_system/tokens_test.dart` | All tests passed (15); с `--dart-define=DS_TOKENS_JSON=<копия с лишним exception>` — тест контраста падает |

### 5.1. Версия 1.1.0 (2026-10-29, ADR-111)

| Проверка | Результат |
|---|---|
| Схема по мета-схеме 2020-12; `tokens.json` по схеме (в том числе `alternatives.B_2026_10_21`, `status: rollback`) | 0 ошибок |
| `gen_tokens_dart.py` дважды во временные каталоги + `diff -r` | пустой вывод, код 0 |
| `gen_tokens_dart.py pos-app/lib/design_system/tokens --check` (в том числе после `dart format --page-width 120` по каталогу) | «checked 8 files, 0 differ», код 0 |
| Вывод генератора (и с `--with-alternative-a`) после `dart format --page-width 120` | «Formatted 16 files (0 changed)», то есть вывод уже отформатирован |
| `check_contrast.py` | 90 пар: PASS 70, FORBIDDEN 9, DECOR 6, EXCEPTION 2, REFERENCE 3; нарушений 0, расхождений 0, ошибок 0, `RESULT: OK` |
| Отрицательные тесты `check_contrast.py` (копии во временном каталоге) | CP-032 `forbidden` при 4.64 → код 1 (2 ошибки); без CP-087 → код 1; `primary` #FF8700 при CP-032 `allowed` → код 1 (2 нарушения и ошибка статуса) |
| `flutter test test/design_system --exclude-tags golden` | All tests passed (в т. ч. `tokens_test.dart`: JSON = Dart для `lightB` и `lightB20261021`, layout, «allowed ⇔ ≥ 4.5»); отрицательная проверка на копии с CP-032 `forbidden` — тест падает |

До 2026-10-29 `gen_tokens_dart.py --check` возвращал 1: 7 из 8 файлов в репозитории были отформатированы `dart format`,
а генератор писал неформатированный код. Это ломало и шаг CI «Генераторы: повторная генерация (`make gen`) даёт пустой
diff». Теперь генератор пишет уже отформатированный код (§4 «Форматирование»), поэтому `dart format` и `--check` больше
не спорят.

### 5.2. Версия 1.0.0 (2026-10-21)

| Проверка | Результат |
|---|---|
| Схема по мета-схеме 2020-12; `tokens.json` по схеме | 0 ошибок |
| Два прогона генератора во временные каталоги + `diff -r` | вывод пустой, код 0; `--check` — «checked 8 files, 0 differ» |
| `check_contrast.py` | 83 пары: PASS 61, FORBIDDEN 12, EXCEPTION 2, DECOR 5, REFERENCE 3; нарушений 0, расхождений с 03 — 0, `RESULT: OK` |
| Отрицательные тесты | `primaryText=#FF8700` → код 1 (6 нарушений и 13 расхождений); белый на primary со статусом `allowed` → код 1; невалидный JSON → генератор, код 2; изменённый файл → `--check`, код 1 |
| Временный Flutter-проект (3.38.7, вне репозитория): `flutter analyze` сгенерированных файлов (с `lightA` и без) | No issues found |
| Smoke-тест `flutter test` (значения B, A, 14 контрольных точек сетки §7.3, брейкпоинты, плотность, шкалы, reduce-motion) | All tests passed |
