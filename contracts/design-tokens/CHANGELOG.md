# CHANGELOG — токены дизайн-системы (`contracts/design-tokens/tokens.json`)

Формат — по [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/); версия — `meta.version` в `tokens.json`
(SemVer: мажор — переименование или удаление токена, минор — новые токены или новые значения, патч — уточнение
описаний и примечаний). Шаг 16 CI (`contracts-lint`) требует запись с новой версией при каждом изменении `tokens.json`.
Dart-классы `pos-app/lib/design_system/tokens/*.dart` генерируются `scripts/gen_tokens_dart.py` и руками не правятся.

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
