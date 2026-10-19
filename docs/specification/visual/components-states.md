# Матрица компонентов и состояний «Оптомстрой POS» (visual/components-states.md)

Версия 1.6 (сверка с ядром R0 v1.8, §23; ранее 1.5 — v1.4, далее v1.3, v1.2 и доработка по замечаниям проверяющего) · Дата 2026-10-19 · Статус: **черновик для утверждения заказчиком** · Тип материала: **структурная схема для ТЗ — не финальный интерфейс**

Входные материалы: `R0_DECISION_KERNEL.md` (§8.1 токены цвета `ds.color.*`, §8.2 типографика `ds.text.*`, §8.3 отступы/радиусы/тени, §8.4 длительности, §8.5 канонические компоненты, §9 экраны, D-16, D-17, D-40, D-43; §16 дополнения v1.1; §17 дополнения v1.2 — приоритет, в т. ч. §17.5 токены `iconButtonPressed`/`onSuccess`/`onError`/`onBrandAccent`, кривые `ds.motion.curve.*`, `reduceMotion`, 18 новых компонентов; §18 дополнения v1.3 — высший приоритет: §18.1 владелец компонентов, токенов, ID `ANIM-0NN` и ключей ARB — 03, §18.2 п. 15 токены `inverseSurface`/`onInverseSurface`, пространства `ds.space.*`/`ds.radius.*`/`ds.elevation.*`; §19 дополнения v1.4 — высший приоритет: §19.1 02 — единственный канонический текст спецификации экранов, §19.2 API и перечень R2, §19.3 `StepUpDialog` и `RegistrationStepper`, §19.4 `QuantityStepper`, `QrPanel`, `AppBottomSheet` `side`, ANIM-029/030; §23 дополнения v1.8 — высший приоритет: §23 п.3 смена способа оплаты без step-up, п.4 `review_reason` с `late_payment`, п.5 отказы в долге, п.8 действия SCR-39 и SCR-45; правило — у документа-владельца, здесь только состояния компонентов), `R4_UX_RESEARCH.md` (§3.2 токены и состояния варианта A, §3.3 вариант B, §3.4 контраст, §6 таблица компонентов, §7 анимации, §9 A11Y), реестр `REQ_REGISTER_A…F.md`.

Связанные документы: [screen-map.md](screen-map.md), [navigation.md](navigation.md), [responsive-spec.md](responsive-spec.md), [README.md](README.md), [03_UX_UI_DESIGN_SYSTEM.md](../03_UX_UI_DESIGN_SYSTEM.md) (владелец `DS-`, `A11Y-`, `ANIM-`; §9 — каноническая спецификация компонентов), [02_SCREEN_SPECIFICATION.md](../02_SCREEN_SPECIFICATION.md) (единственный канонический текст спецификации экранов — R0 §19.1; части `02a…02e` перенесены в `source/02_parts_drafts/` как нерабочие черновики, ссылки на экраны ведутся на разделы 02 §9 «Часть A…E»), [08_API_SPECIFICATION.md](../08_API_SPECIFICATION.md) (пути запросов в состояниях `loading`). Ядро и исследование: [R0](../../research/R0_DECISION_KERNEL.md), [R4](../../research/R4_UX_RESEARCH.md). Далее в тексте документы упоминаются кратко (R0, R4, 03, 08 …) — ссылки на файлы приведены здесь.

---

## Краткое содержание

- Матрица «**компонент × состояние**» для всех 59 канонических компонентов R0 §8.5 в 62 строках §2.1–§2.5 и 18 компонентов R0 §17.5 в §9.1 (итого 77) (`AppButton` — 6 строк-вариантов: primary, secondary/tonal, outlined, text, danger, success — вариант `success` в перечне R0 §8.5 отсутствует и канонизирован в 03 §9.1 (R0 §17.5: каноническая спецификация компонентов — 03 §9); `FilterPanel`/`FilterSheet` и `SkeletonBox`/`SkeletonList` — по одной строке на пару); полное отображение enum-статусов на `StatusChip` — §2.6 и десяти состояний: `default`, `hover`, `pressed`, `focused`, `disabled`, `loading`, `error`, `selected`, `empty`, `offline`. В ячейках — имена токенов ядра (`ds.color.*`, `ds.text.*`, `r-*`, `elev*`) и ссылки на анимации.
- Анимации обозначены каноническими ID `ANIM-001…ANIM-030` (+ `ANIM-R2-001`; ANIM-029/030 — видоискатель камеры SCR-17, R0 §19.4) из `03_UX_UI_DESIGN_SYSTEM.md` §11.2 — владелец ID анимаций 03 (R0 §18.1); предварительные ID `ANIM-01…ANIM-20` (= строки R4 §7.2 #1…#20) из ячеек §2–§3 заменены по таблице соответствия §9.4 и сохраняются только в §9.4 для трассировки.
- Таблица «**компонент → экраны**» (§4) показывает, где каждый компонент используется, и служит для проверки полноты `02_SCREEN_SPECIFICATION.md`.
- Общие правила состояний (§1): hover — только при указателе (mouse/trackpad), focused — кольцо `focus` 2 px + 2 px отступ, disabled исключён из требований контраста, статусы — всегда «цвет + иконка + текст» (A11Y-004), `reduceMotion` → crossfade ≤ 80 мс или статичный кадр (R0 §17.5).
- Ядро v1.2 (R0 §17) внесено **прямо в строки §1–§4** (токены `onError`/`onSuccess`, reduce-motion, `SuccessCheck`, `WarehouseStockTable`, `RegistrationStepper`); §9 содержит самостоятельные таблицы для 18 новых компонентов и журнал: матрица и таблица «компонент → экраны» для 18 новых компонентов R0 §17.5 (итого 77), окончательные ID анимаций `03` §11.2, новые коды ошибок (`PIN_LOCKED`, `CONSENT_REQUIRED`, `APP_READ_ONLY`, `STALE_DATA` …) и правила step-up/разделения обязанностей.
- Ядро v1.3 (R0 §18, высший приоритет) внесено прямо в строки: `AppSnackbar`/`AppTooltip` — токены `inverseSurface #1B1F2A`/`onInverseSurface #FFFFFF`; ID анимаций — канонические `ANIM-0NN` (03 §11.2); `SuccessCheck` при reduce-motion — crossfade ≤ 80 мс; `r-xl 20` — SCR-01…SCR-04 и SCR-08, SCR-06/SCR-07 — `r-lg 16`; ключи ARB — владелец 03; журнал — §10.
- Ядро v1.4 (R0 §19, высший приоритет) внесено прямо в строки: `QuantityStepper` — «−» на минимуме в корзине = удаление строки **с подтверждением** (CART-003/012), debounce **500 мс**, при неизвестном остатке добавление запрещено (INV-052); `StepUpDialog` — PIN 5 попыток (счёт из ответа сервера), кнопка биометрии в R1 скрыта, на compact — нижний лист, вариант `supervisor` — **R2**; `QrPanel` — «Обновить QR» на том же `payment_id`, показ также в `awaiting_payment`; `AppBottomSheet` `side` — 400 (medium) / 480 (expanded); `RegistrationStepper` — 3 шага «Данные · Защита входа · Готово» (+ «Привязка» при SCR-06); ANIM-029/030 (§3). Журнал — §10.
- Палитра — вариант **A+** (D-16); вариант B (Q-006) использует те же имена токенов с другими значениями (R4 §3.3), поэтому матрица от варианта не зависит, кроме примечаний к `brandAccent`.

---

## 1. Общие правила состояний

| № | Правило | Токены / значения | Источник |
|---|---|---|---|
| ST-1 | `hover` применяется только при наличии указателя (`MouseRegion`); на тач-устройствах состояние не показывается | `surfaceHover #F8FAFC`, `primaryHover #0047DB`; 150 мс (`fast`) | R4 §6, §7.2 #15; R0 §8.4 |
| ST-2 | `pressed` — мгновенная реакция ≤ 150 мс; для filled-кнопок `primaryPressed #003BB8` + scale 0.98; для строк — `surfacePressed #EEF1F5`; для outlined/tonal — `primaryContainerPressed #D6E3FF`; для иконок-кнопок и ореола контролов (`AppCheckbox`/`AppRadio`/`AppSwitch`) — `iconButtonPressed #E2E6EC` (R0 §17.5) | `fast` | R4 §3.2, §6 |
| ST-3 | `focused` — кольцо `focus #0053FA` 2 px с отступом 2 px (снаружи элемента), радиус элемента + 2; показывается при клавиатурной навигации (`FocusHighlightMode.traditional`) и всегда для полей ввода (`border primary 2 px`) | `focus`, `r-*` | R0 §8.1, A11Y-002 |
| ST-4 | `disabled` — `disabledBg #E5E7EB` / `disabledText #9CA3AF`, иконки 38 % непрозрачности; контраст не требуется (исключение WCAG 1.4.3); тач-цель сохраняется, тап даёт `AppSnackbar` с причиной, если она известна (например «Нет остатка») | — | R4 §3.4 |
| ST-5 | `loading` — спиннер 16–20 в кнопке (текст скрыт, ширина фиксируется), `SkeletonBox` для контента при ожидании > 300 мс (`ANIM-013`), прогресс-бар при > 10 с | `skeletonBase #EEF1F5` → `skeletonHighlight #E4E7EC` | R4 §2.3 (NN/g), §7.2 #12 |
| ST-6 | `error` — `error #C62828` для текста/иконки/обводки, `errorContainer #FDE2E2` для фона; всегда иконка + текст; shake ±4 lp 1 раз только для полей ввода (`ANIM-012`) | `error`, `errorContainer` | A11Y-004, R4 §7.2 #6 |
| ST-7 | `selected` — `primaryContainer #E5EEFF` + левая полоса 3 px `primary` (строки, категории) **или** обводка `primary` 2 px + `primaryContainer` (плитки) **или** filled-иконка `primary` (навигация); никогда — сплошная заливка `primary` больших площадей (утомляемость, R4 §3.5) | `primaryContainer`, `primary` | R4 §3.2 |
| ST-8 | `empty` — `EmptyState` (иллюстрация с `brandAccent #FF8700` как акцент, заголовок `h3`, причина `body` `textSecondary`, кнопка-действие); не показывать «пусто», пока идёт загрузка | — | R4 §2.3 (NN/g), §6 #36 |
| ST-9 | `offline` — компонент работает по кэшу: данные показываются с подписью возраста («на 09:41»), действия, требующие сети (заказ, оплата, долг), переходят в `disabled` с подсказкой; `OfflineBanner` глобален | `warning`, `warningContainer #FEF3C7` | D-32, NFR-OFFLINE-001 |
| ST-10 | Все статусы (остаток, оплата, синхронизация, долг) — цвет + иконка + текст; красно-зелёные пары неразличимы при дальтонизме (R4 §3.4) | `success/warning/error/info` + `*Container` | A11Y-004 |
| ST-11 | Переходы между состояниями — `fast 150` (hover/pressed/чипы), `base 200` (появление, переключатели), `slow 300` (экраны, sheet); кривые — токены `ds.motion.curve.{standard, standardDecelerate, standardAccelerate, emphasized}` (R0 §17.5); `reduceMotion` → crossfade ≤ 80 мс или статичный кадр (R0 §17.5): шиммер статичный, персонаж — статичные кадры, смены состояний — crossfade ≤ 80 мс | R0 §8.4, §17.5 | D-40, A11Y-006 |
| ST-12 | Тёмная тема — не в R1 (D-43); токены именованы семантически, чтобы матрица не менялась при добавлении темы | — | Q-006 |

Сокращения в матрице: **bg** — фон, **fg** — текст/иконка, **bd** — обводка, **—** — состояние неприменимо, **=def** — как default. Токены — короткие имена из R0 §8.1 (`primary` = `ds.color.primary`); `r-xs…r-full` = `ds.radius.{xs,sm,md,lg,xl,full}`, `elev0…elev3` = `ds.elevation.{0,1,2,3}`, `space1…space10` = `ds.space.1…10` (канонические пространства имён — R0 §18.2 п. 15). Анимации — канонические ID `ANIM-0NN` из 03 §11.2 (R0 §18.1).

---

## 2. Матрица «компонент × состояние»

### 2.1. Кнопки и поля ввода

| Компонент (варианты) | default | hover | pressed | focused | disabled | loading | error | selected | empty | offline |
|---|---|---|---|---|---|---|---|---|---|---|
| `AppButton` primary (S 36 / M 44 / L 52 видимые; цель S 44 / M 48 / L 52 — 03 §7.4; `r-sm`, `label`/`body` 600) | bg `primary`, fg `onPrimary` | bg `primaryHover` (ANIM-015) | bg `primaryPressed`, scale .98 | кольцо `focus` | bg `disabledBg`, fg `disabledText` | спиннер 16 `onPrimary`, текст скрыт, ширина фикс. | — (ошибка — snackbar/inline) | — | — | как disabled, если действие требует сети (подсказка) |
| `AppButton` secondary/tonal | bg `primaryContainer`, fg `primary` | bg `primaryContainerPressed` на 50 % | bg `primaryContainerPressed` | кольцо | `disabledBg`/`disabledText` | спиннер `primary` | — | — | — | как primary |
| `AppButton` outlined («Отложить заказ») | bd `primary` 1.5, fg `primary`, bg `surface` | bg `primaryContainer` | bg `primaryContainerPressed` | кольцо | bd `disabledBg`, fg `disabledText` | спиннер | — | — | — | как primary |
| `AppButton` text/link («Изменить», «Очистить») | fg `primary` | подчёркивание | fg `primaryPressed` | кольцо | fg `disabledText` | — | — | — | — | — |
| `AppButton` danger («Запросить отмену», «Выйти») | bg `error`, fg `onError #FFFFFF` (filled, R0 §17.5) / fg `error` (text) | bg темнее на 8 % (`Color.lerp(error, textPrimary, .08)`, 03 §9.1) | темнее на 20 % `[ТИПОВО]` | кольцо `focus` (синее — контраст к красному) | `disabledBg` | спиннер `onError` | — | — | — | disabled |
| `AppButton` success («Создать заказ и показать QR»; вариант канонизирован в 03 §9.1, в перечне вариантов R0 §8.5 отсутствует — см. §7 п. 5) | bg `success #15803D`, fg `onSuccess #FFFFFF` (R0 §17.5; не макетный #0D9E48 — R4 §3.2) | темнее 10 % `[ТИПОВО]` | темнее 20 % `[ТИПОВО]` | кольцо | `disabledBg` | спиннер `onSuccess` | — | — | — | disabled (заказ только онлайн) |
| `AppIconButton` (40 визуально / 48 цель) | fg `textSecondary` | bg `surfaceVariant` | bg `iconButtonPressed #E2E6EC` (R0 §17.5) | кольцо | fg `disabledText` | — | fg `error` (только для «ошибка синхронизации») | fg `primary` filled (напр. фильтр активен) с точкой-бейджем | — | — |
| `AppTextField` (S/M/L, `r-sm`, bd `borderStrong`) | bg `surface`, bd `borderStrong` 1, label `label` `textSecondary`, placeholder `textTertiary` | bd `textSecondary` | — | bd `primary` 2 | bg `disabledBg`, fg `disabledText` | спиннер 16 в суффиксе (серверная проверка) | bd `error` 2, helper `caption` `error`, иконка `error` (shake ANIM-012 только при submit) | — | placeholder | =def; серверная валидация отложена с подписью |
| `PhoneField` («+996 XXX XXX XXX» — формат R0 §17.2, хранение E.164; `phone_numbers_parser`) | префикс «+996» `textSecondary`, маска | как TextField | — | bd `primary` | disabled | спиннер в суффиксе | «Введите 9 цифр» / `PHONE_ALREADY_REGISTERED` | — | маска | =def |
| `OtpField` (6 ячеек 48×56, `tabularFigures` 24/600) | ячейки bd `borderStrong`, bg `surface` | — | — | активная ячейка bd `primary` 2 + курсор | после `OTP_LOCKED`: все `disabledBg` + текст cooldown | ячейки пульсируют (opacity 1→.6, ANIM-004-аналог 1,2 с loop) | все ячейки bd `error`, shake 1 раз (ANIM-012), текст `OTP_INVALID`/`OTP_EXPIRED` | заполненная ячейка bg `primaryContainer` | пустые ячейки | кнопка «Повторно» disabled + «Нет сети» |
| `PinField` (4–6 ячеек, скрытый ввод — точки) | как OtpField | — | — | как OtpField | после **5** неверных вводов подряд — `423 PIN_LOCKED`: ячейки `disabledBg`, текст «PIN заблокирован. Войдите по номеру телефона» + ссылка на SCR-01 (разблокировка только через OTP) `[РЕШЕНИЕ: 09 BIO-020, D-48; Q-004, Q-163]` | проверка на сервере (`POST /auth/unlock` на SCR-08, `POST /auth/step-up` в `StepUpDialog`; R0 §18.2 п. 5): точки пульсируют | shake + «Неверный PIN. Осталось попыток: {n}» (`attemptsLeft` из `401 PIN_INVALID`; `/auth/refresh` на этот код не вызывается — R0 §18.2 п. 5) | — | — | PIN проверяется **на сервере** (D-48): офлайн поле disabled с подсказкой «Нужна сеть для проверки PIN» (офлайн-разблокировка вне R1, Q-241) |
| `SearchBar` (header 56 / compact 48, bg `surfaceVariant`, `r-sm`, лупа слева, сканер справа) | bg `surfaceVariant`, placeholder «Поиск товара по названию, коду или штрих-коду…» `[ПОДТВЕРЖДЕНО: макет]` | bg `surfaceHover` | — | bg `surface`, bd `primary` 2 | — | индикатор debounce: тонкая полоса `primary` под полем 300 мс (ANIM-013-подобная) | — | — | кнопка «×» очистки; при 0 результатов — `EmptyState` search в контенте | =def; поиск по кэшу, подпись «Офлайн: поиск по сохранённому каталогу» |
| `DiscountInput` (поле + сегмент %/сом) | bg `surface`, bd `borderStrong`, значение `tabularFigures` | bd `textSecondary` | — | bd `primary` | без права — скрыт; сверх лимита — поле `warning` + кнопка «Запросить подтверждение» | спиннер при `POST /cart/discount` (08 §4.7.5) | bd `error` + «Макс. 5 % для вашей роли» (`DISCOUNT_LIMIT_EXCEEDED`) | — | «0» | disabled: «Скидка применяется онлайн» |
| `DateRangePicker` (кнопка-поле + календарь popover/диалог) | bg `surface`, bd `borderStrong`, текст «29.06–29.06.2026» | bd `textSecondary` | — | bd `primary` | disabled | — | «Начало позже конца» `error`; период журналов > **366 дней** — «Период не более 366 дней» `error` `[РЕШЕНИЕ: ядро §19.4]` (значения по умолчанию — Q-215) | выбранные дни bg `primaryContainer`, границы диапазона bg `primary` | «Период» placeholder | =def |

### 2.2. Каталог и товар

| Компонент | default | hover | pressed | focused | disabled | loading | error | selected | empty | offline |
|---|---|---|---|---|---|---|---|---|---|---|
| `CategorySidebarItem` (48–53, иконка 24, счётчик `label` `textSecondary`) | bg `surface`, fg `textPrimary` | bg `surfaceHover` | bg `surfacePressed` | кольцо внутри строки | — | `SkeletonBox` строки (иконка круг + текст 60 %) | — | bg `primaryContainer` + полоса 3 `primary` слева, fg `primary`, иконка filled (вместо сплошной синей заливки макета — R4 §3.2) | счётчик «0» `textTertiary`, строка остаётся | =def; счётчики из кэша |
| `CategoryChip` (choice/filter, 36 высота, цель 48 — iOS 44 pt, `r-full`) | bg `surface`, bd `border`, fg `textPrimary` | bg `surfaceVariant` | bg `surfacePressed` | кольцо | `disabledBg` | скелетон-чипы 3 шт. | — | bg `primaryContainer`, bd `primary`, иконка check, обводка скользит (ANIM-017, 200 мс — 03 §11.2) | — | =def |
| `ProductCardGrid` (bg `surface`, bd `border`, `r-md`, `elev0`; фото 1:1, название `body` 2 строки, артикул `caption`, `PriceText` `title` 700, `StockBadge`, кнопка «+ Добавить» M) | =описание | `elev1` + bd `borderStrong` 50 % (ANIM-015) | scale .99 | кольцо вокруг карточки | «Нет в наличии»: кнопка disabled, фото opacity .6, `StockBadge` out; «Остаток неизвестен» — кнопка «+ Добавить» disabled с подписью «Остаток неизвестен», добавление запрещено `[РЕШЕНИЕ: ядро §19.4; 10 INV-052]` | `SkeletonBox` карточки (фото, 2 строки, цена, кнопка) — `ANIM-013` | фото-заглушка `ProductImage` error; при ошибке добавления — кнопка shake (ANIM-012) + `StockBadge` warning | «в корзине»: кнопка → `QuantityStepper` (crossfade 200, ANIM-006), бд карточки `primary` 1.5 | — | =def; цена/остаток с подписью возраста при > 15 мин |
| `ProductCardList` (72, миниатюра 48, название 1 строка, артикул, остаток, цена, степпер) | bg `surface`, разделитель `border` | bg `surfaceHover` | bg `surfacePressed` | кольцо | как Grid | скелетон строки | заглушка фото | полоса 3 `primary` слева | — | как Grid |
| `ProductCardCompact` (48, 1 строка: артикул / название / остаток / цена / qty, `tabularFigures`) | bg `surface`, зебра `surfaceVariant` для чётных `[ТИПОВО]` | bg `surfaceHover` | bg `surfacePressed` | кольцо/фокус строки (клавиатура POS) | fg `disabledText` для «нет в наличии» | скелетон строки | — | bg `primaryContainer` | — | как Grid |
| `ProductImage` (thumb 160 / card 400 / full 1200, `cached_network_image`, `r-sm`) | фото на bg `surfaceVariant` | — | — | — | opacity .6 | `SkeletonBox` + шиммер | заглушка «Нет фото» (иконка `image` `textTertiary`), никогда чужое фото (D-30) | рамка `primary` 2 (галерея) | заглушка | из кэша; если нет — заглушка с иконкой `cloud_off` |
| `PriceText` (`tabularFigures`, 700; 16 список / 18 сетка / 20–24 карточка / 32 итог; «2 350 сом», разряды тонким неразрывным пробелом) | fg `primary` (цена) `[ПОДТВЕРЖДЕНО: макет]`, старая цена `textTertiary` зачёркнута | — | — | — | fg `disabledText` | `SkeletonBox` 80×18 | «Цена изменилась» — `warning` + иконка, старое значение зачёркнуто (ANIM-010 перекат числа) | — | «—» | fg `textPrimary` + подпись «на 09:41» |
| `StockBadge` (in-stock / low / out / by-warehouse; `caption` 500 + иконка 16, `r-xs`) | in-stock: bg `successContainer`, fg `success`, «В наличии · 24 шт»; low: `warningContainer`/`warning` «Мало · 3 шт»; out: `errorContainer`/`error` «Нет в наличии» | by-warehouse: tooltip/раскрытие `WarehouseStockTable` | — | — | — | скелетон 64×18 | «Остаток неизвестен» `textSecondary` на `surfaceVariant` + иконка `help` (03 §9); добавление в корзину запрещено — «+ Добавить» и «+» степпера disabled `[РЕШЕНИЕ: ядро §19.4; 10 INV-052]` | — | «Нет данных» | подпись возраста «(на 09:41)» `textTertiary`; при > `NFR-SYNC` порога — `warning` |
| `UnitSelector` (чипы единиц/упаковок «шт», «кор. ×10», `r-full`) | bg `surface`, bd `border` | bg `surfaceVariant` | — | кольцо | «нет остатка в упаковке» — `disabledText` | — | — | bg `primaryContainer`, bd `primary` | один вариант — чип не показывается | =def |
| `QuantityStepper` (sm 36 / md 44 видимые; цель 48 на тач-устройствах во всех плотностях — `responsive-spec.md` §1.6; «−» поле «+»; `tabularFigures`) | кнопки `AppIconButton`, поле bd `borderStrong` | кнопки hover | кнопки `pressed`; удержание > 500 мс — автоповтор каждые 150 мс (ANIM-007, 03 §11.2) | поле bd `primary` (ввод с клавиатуры) | «−» на минимуме (1 шаг / кратность) у строки **в корзине** не disabled: тап (или ввод 0) → `ConfirmDialog` destructive «Удалить позицию из корзины?» («Отмена» возвращает прежнее количество; после «Удалить» — ANIM-008 + снекбар «Отменить» 5 с) `[РЕШЕНИЕ: ядро §19.4; 10 CART-003, CART-012]`; вне корзины (выбор количества до добавления, SCR-14/15/39) «−» disabled при min; «+» disabled при max = доступно; при неизвестном остатке «+» disabled — добавление запрещено `[РЕШЕНИЕ: ядро §19.4; 10 INV-052]` | изменение уходит на сервер с debounce **500 мс** (один `PUT /cart/items/{variantId}` на серию нажатий, optimistic-обновление) `[РЕШЕНИЕ: ядро §19.4; 10 INV-043]`; число crossfade при синхронизации (ANIM-010) | число fg `error` + shake при > остатка / `QTY_NOT_MULTIPLE` + helper «Кратность: 10 шт»; ошибка сервера после debounce — откат + `AppSnackbar` | — | — | работает по кэшу; сервер сверит позже (outbox) |
| `QuantityNumpadSheet` (клавиши 64×56, дисплей 32/700 `tabularFigures`) | клавиши bg `surface`, bd `border` | клавиши `surfaceHover` | клавиши `surfacePressed` (ANIM-015) | — | «,» disabled при `qtyPrecision=0`; «OK» disabled при 0 (для строки корзины «OK» с 0 — запрос на удаление с подтверждением `ConfirmDialog` destructive, `[РЕШЕНИЕ: ядро §19.4; 10 CART-012]`) | — | дисплей `error` + «Макс. 240 шт» / «Кратность: 10» | — | дисплей «0» `textTertiary` | =def |
| `VariantSelector` (chips / swatches 40 / dropdown; чип с артикулом) | bd `border`, fg `textPrimary` | bg `surfaceVariant` | pressed | кольцо | «нет в наличии» — зачёркнут, fg `disabledText`, остаётся выбираемым для просмотра `[ТИПОВО]` | скелетон-чипы | — | bd `primary` 2, bg `primaryContainer`, свотч — кольцо `primary` | единственный вариант — селектор скрыт | =def |
| `FavoriteToggle` (звезда 24, цель 48) | контур `favorite` с обводкой `warning #B45309` (выкл.) | bg `surfaceVariant` | scale 1→1.3→1 200 мс (ANIM-009, 03 §11.2) | кольцо | — | — | откат с snackbar «Не удалось сохранить» | filled `favorite #FEC50A` `[ПОДТВЕРЖДЕНО: макет]` | — | оптимистично переключается, уходит через outbox (D-32) как `PUT`/`DELETE /favorites/{products\|customers}/{id}` `[РЕШЕНИЕ: ядро §19.4]`; на карточках каталога иконка избранного — только звезда (R0 §19.4) |
| `SortMenu` (поле с иконкой `swap_vert`, «По возрастанию цены» `[ПОДТВЕРЖДЕНО: макет]`; в каталоге и поиске дополнительно «Сначала в наличии» `available:desc` и «По артикулу» `sku:asc` `[РЕШЕНИЕ: ядро §19.2]`, Q-204 — закрыт решением ядра v1.4) | bg `surface`, bd `border`, `r-sm` | bg `surfaceVariant` | — | кольцо | — | — | — | пункт меню с check `primary`, bg `primaryContainer` | — | =def |
| `FilterPanel` / `FilterSheet` | bg `surface`, группы с заголовками `label`, чекбоксы bd `borderStrong` | строка `surfaceHover` | — | кольцо на контроле | группа без значений — скрыта | скелетон групп | «Цена от > до» `error` | активные фильтры — чип `selected` + бейдж-счётчик на кнопке «Фильтры» | «Фильтры недоступны для этой категории» | =def; значения из кэша |
| `ViewModeSegmented` (Сетка/Список/Компакт, bg `surfaceVariant`, `r-sm`) | сегменты fg `textSecondary` | fg `textPrimary` | — | кольцо | — | — | — | bg `surface` + `elev1`, fg `primary` `[ПОДТВЕРЖДЕНО: макет]`; индикатор скользит 200 мс (ANIM-017) | — | =def |

### 2.3. Корзина и оформление

| Компонент | default | hover | pressed | focused | disabled | loading | error | selected | empty | offline |
|---|---|---|---|---|---|---|---|---|---|---|
| `CartPanel` (desktop 320–340 / mobile экран / tablet overlay; bg `surface`, `elev1`, bd `border` слева) | заголовок `h3` «Корзина» + бейдж `AppBadge` (`error`, число `micro` `onError`) `[ПОДТВЕРЖДЕНО: макет]`, список, скидка, итоги, 2 кнопки | — | — | — | кнопки «Создать заказ» disabled при пустой корзине / невалидных строках | `SkeletonList` 3 строки при загрузке `/cart` | баннер `warningContainer` «Цены/остатки изменились» + список строк (ANIM-019 fade-in); при `ONEC_UNAVAILABLE` — `infoContainer` «1С недоступна: заказ уйдёт в очередь» | — | `EmptyState` cart («Корзина пуста», иллюстрация `brandAccent`, кнопка «К каталогу»); на compact панель-итог скрыта | баннер `warningContainer` «Офлайн: корзина сохранена локально», «Создать заказ» disabled, «Отложить» доступно локально |
| `CartLine` (72 standard / 64 compact: миниатюра 48/40, название 2 строки, `QuantityStepper` sm, сумма `tabularFigures` 700, крестик) | bg `surface`, разделитель `border` | bg `surfaceHover` | свайп влево (compact) — фон `errorContainer` + иконка удаления | кольцо строки (клавиатура: `↑/↓`) | — | сумма crossfade (ANIM-010) | bd `error` 1.5 + `StockBadge` «Доступно 3» при qty > остатка; `VARIANT_UNAVAILABLE` — строка `errorContainer` + «Убрать» | bg `primaryContainer` (строка в фокусе на POS) | — | =def |
| `CartSummary` («Товаров (5) 16 850 сом», «Скидка −842,50», «Итого 16 007,50» `display`/`h2` `primary` 700) | bg `surfaceVariant`, `r-md`, суммы `tabularFigures` | — | — | — | — | суммы — `SkeletonBox` при пересчёте > 300 мс; перекат числа (ANIM-010) | «Итог не подтверждён сервером» `warning` | — | нули `textTertiary` | «Итог по кэшу, уточнится онлайн» `caption` `warning` |
| `CheckoutStepper` (horizontal / compact «Шаг 2 из 4») | done: круг `success` + ✓ `onSuccess` (R0 §17.5); active: пилюля `surfaceVariant` с цифрой `textPrimary` `[ПОДТВЕРЖДЕНО: макет]` (альтернатива — `primary`); upcoming: круг bd `border`, fg `textTertiary`; соединители `border` | кликабельные пройденные шаги — fg `primary` | — | кольцо на кликабельном шаге | непройденные шаги не кликабельны | — | шаг с ошибкой валидации: круг `error` + «!» | active | — | шаг «Оплата»: метод «долг» disabled офлайн |
| `PaymentMethodCard` / плитка выбора (72, иконка 24, заголовок `body` 500, подпись `caption`, `r-md`) | bg `surface`, bd `border` | bg `surfaceHover` | bg `surfacePressed` | кольцо | bd `border`, fg `disabledText`, подпись причины по `creditReason` («Долг: просрочка», `CREDIT_BLOCKED`, в т. ч. `credit_not_allowed` — «Отсрочка не разрешена соглашением»; клиент не выбран или «Розничный покупатель» — `CUSTOMER_NOT_IDENTIFIED`; 10 PAY-031, ядро §23 п.5) | спиннер при проверке долга (`/inventory/check`, `/customers/{id}/receivables`) | bd `error` + подпись (`RECEIVABLES_STALE`) | bd `primary` 2 + bg `primaryContainer` + радио/check `primary` `[ПОДТВЕРЖДЕНО: макет]` | — | QR/долг disabled; наличные — доступны только после подключения (заказ онлайн) |
| `CustomerPicker` (поиск + результат + выбранная `CustomerCard` compact) | поле как `SearchBar`, подсказка «Введите имя, телефон или часть имени…» `[ПОДТВЕРЖДЕНО: макет]` | строка результата `surfaceHover` | pressed | bd `primary` | — | спиннер в поле; результаты — `SkeletonList` 3 | «Клиент не найден» + кнопка «+ Новый клиент» (не ошибка, а `empty`); сетевой сбой — `ErrorState` inline | выбранный клиент — `CustomerCard` compact с крестиком | «Розничный покупатель» (системный клиент, Q-026) по умолчанию `[ТИПОВО]` | поиск по кэшу клиентов; «+ Новый клиент» disabled офлайн (дедупликация в 1С); финансовые данные найденного клиента офлайн не показываются (R0 §19.4). Порог запуска поиска: `cashier`, `senior_seller`, `admin`, `owner` — от 4 цифр телефона или 2 букв имени; `seller` — только полный номер или код клиента, до порога — подсказка без результатов `[РЕШЕНИЕ: ядро §19.4]` |
| `PrintOptions` (чекбоксы: счёт на оплату · накладная · товарный чек; `r-md`, bg `surfaceVariant`) | чекбоксы вкл. по умолчанию `[ПОДТВЕРЖДЕНО: макет]`, подпись «нефискальный» у чека (D-26) | строка hover | — | кольцо | «накладная» disabled с подписью «Печатается из 1С» (D-27; по умолчанию `available:false`); «товарный чек» disabled до получения оплаты («Чек — после оплаты»); «счёт» доступен после создания заказа `[РЕШЕНИЕ: ядро §19.4]` | после создания: строки со спиннером «Формируем PDF…» | «Не удалось сформировать» + «Повторить»; печать не блокирует заказ | checked bg `primary` | — | disabled: «Печать после подключения» |
| `QrPanel` (QR 240–320, сумма `display`, таймер, статус) | QR на bg `surface`, bd `border`, `r-lg`; статус `StatusChip` info «Ожидаем оплату»; QR показывается для заказа в статусах `submitting`, `pending_approval`, `approved` и также `awaiting_payment` `[РЕШЕНИЕ: ядро §19.4]` | — | — | — | — | QR — `SkeletonBox` 240×240 + `AppProgress` «Формируем QR…» (QR-платёж создаётся в составе `POST /orders` при выбранном способе QR `[РЕШЕНИЕ: ядро §19.2]`) | `qr_expired`: QR затемнён + «QR истёк» + «Обновить QR» — перевыпуск на **том же `payment_id`** (новые `qrPayload` и срок; новый платёж не создаётся, номер платежа в UI не меняется) `[РЕШЕНИЕ: ядро §19.2; 10 PAY-025]`; нет API (Q-014): `infoContainer` «Подтвердите оплату вручную» + кнопка (step-up); вебхук после истечения QR → `manual_confirm` с чипом `late_payment` (ядро §23 п.4); «Другой способ оплаты» из `qr_shown` — без step-up (прежний платёж аннулирует система, 10 PAY-052), из `qr_expired`/`manual_confirm` — после ручного аннулирования со step-up (ядро §23 п.3) | `received`: QR заменяется `SuccessCheck` (R0 §17.5; ANIM-005, scale 0→1 250 мс), «Оплачено» | — | «QR недоступен офлайн» `ErrorState` |

### 2.4. Клиенты, транзакции, статусы

| Компонент | default | hover | pressed | focused | disabled | loading | error | selected | empty | offline |
|---|---|---|---|---|---|---|---|---|---|---|
| `CustomerCard` (compact в оформлении / full на кассе / row 72 в списках; `AppAvatar` инициалы, имя `body` 500, телефон `caption`, мета «История: 12 заказов · Долг: 0 сом · Скидка: 5 %» `[ПОДТВЕРЖДЕНО: макет]`) | bg `surface`, bd `border`, `r-md` | bg `surfaceHover` | bg `surfacePressed` | кольцо | — | `SkeletonBox` аватар + 2 строки | «Данные клиента недоступны» | row: полоса 3 `primary`; карточка-плитка: bd `primary` | — | мета (имя, телефон, история) из кэша с подписью возраста; финансовые данные (долг, скидка) офлайн не показываются — только значения, уже полученные в памяти текущей сессии, с подписью «на 09:41»; локально не кэшируются `[РЕШЕНИЕ: ядро §19.4, §18.2 п. 1]` |
| `ReceivableBadge` (zero / due / overdue; `tabularFigures` 600 + иконка 16; `r-xs`) | zero: `successContainer`/`success` «Долга нет»; due: `warningContainer`/`warning` «Долг 12 500 сом»; overdue: `errorContainer`/`error` «Просрочено 8 500 сом» | tooltip «Данные 1С на 09:41» | тап → SCR-34 (step-up) | кольцо | — | скелетон 96×18 | «Долг не получен» `textTertiary` + иконка `sync_problem`; онлайн при устаревании (> 60 мин, `RECEIVABLES_STALE`) — бейдж `warning` «Устарело» + действие «Обновить» (`POST /customers/{id}/receivables/refresh`, `cashier`/`senior_seller`/`admin`/`owner`, rate-limit; на время запроса — спиннер 16) `[РЕШЕНИЕ: ядро §19.2]`, Q-221 — закрыт решением ядра v1.4; продажа в долг блокируется до свежего снимка (D-24) | — | — | офлайн долг не показывается (финансовые данные не кэшируются; значение из памяти текущей сессии — с подписью возраста), продажа в долг недоступна `[РЕШЕНИЕ: ядро §19.4]` |
| `TransactionRow` (72/56/48; иконка типа, номер `label`, дата `caption`, клиент, сумма `tabularFigures` 700, `StatusChip`) | bg `surface`, разделитель `border` | bg `surfaceHover` | bg `surfacePressed` | кольцо | — | `SkeletonList` | — | полоса 3 `primary` (деталь открыта справа) | `EmptyState` transactions | =def; список из кэша с подписью |
| `StatusChip` (`caption` 500 + иконка 14, `r-full`, container-фон) | пять семейств: neutral `surfaceVariant`/`textSecondary`; info `infoContainer`/`info`; success `successContainer`/`success`; warning `warningContainer`/`warning`; error `errorContainer`/`error`; распределение **всех** значений `order_status`, `payment_status`, `return_request_status`, `sync_run_status` (+ `outbox_status`, `user_status`, `cart_status`) — таблица §2.6 | tooltip с полным статусом | — | — | — | `submitting`: иконка вращается (ANIM-021) | error-семейство | — | — | =def |
| `SyncIndicator` (в шапке: иконка 20 + «обновлено 09:41» `caption`) | ok: `success` иконка `cloud_done` + текст `textSecondary` | tooltip по сущностям | тап → SCR-43 | кольцо | — | syncing: иконка `sync` вращается 1 с loop (ANIM-021) | error: иконка `error` «Ошибка синхронизации» без вращения | — | — | offline: `cloud_off` `warning` «Нет сети · 09:41» |
| `RoleBadge` (`caption` 500, `r-xs`) | bg `surfaceVariant`, fg `textSecondary` («Продавец», «Старший продавец», «Кассир», «Администратор», «Руководитель») | — | — | — | — | — | — | — | — | =def |
| `AuditRow` (48/56: время `tabularFigures`, пользователь, действие, объект, результат) | bg `surface`, зебра | `surfaceHover` | — | кольцо | — | скелетон | результат `error` для отказов | полоса `primary` | `EmptyState` audit | из кэша не показывается (аудит — только онлайн) `[ТИПОВО]` |
| `AppAvatar` (24/32/40/64; инициалы/фото) | bg `primaryContainer`, инициалы `primary` 600 | — | — | — | opacity .5 | скелетон круг | фото не загрузилось → инициалы | bd `primary` 2 | «?» | =def |
| `NotificationBell` (иконка 24 + бейдж `AppBadge`: `error` `micro` 11/600 `onError`, R0 §17.5) | fg `textSecondary`, бейдж «3» `[ПОДТВЕРЖДЕНО: макет]` | bg `surfaceVariant` | pressed → SCR-44 | кольцо | — | — | — | открыт popover: fg `primary` | без бейджа | =def; новые уведомления после подключения; бейдж из кэша |

### 2.5. Обратная связь, оболочка, навигация

| Компонент | default | hover | pressed | focused | disabled | loading | error | selected | empty | offline |
|---|---|---|---|---|---|---|---|---|---|---|
| `OfflineBanner` (40, bg `warningContainer`, fg `warning`, иконка `cloud_off`, кнопка «Повторить» text) | скрыт | — | — | кольцо на «Повторить» | — | reconnecting: иконка `sync` вращается, «Подключаемся…» (ANIM-021) | — | — | — | показан: «Нет сети · данные на 09:41»; back-online: `successContainer` «Снова в сети» 3 с → скрыть (ANIM-019: 150 мс) |
| `SkeletonBox` / `SkeletonList` (card / row / text / avatar) | bg `skeletonBase #EEF1F5`, блик `skeletonHighlight #E4E7EC` слева направо 1,2 с loop (ANIM-013); `reduceMotion` → статичный кадр | — | — | — | — | =def (это и есть loading) | через 10 с → `ErrorState`-подобный «Долгая загрузка» с «Повторить» | — | — | показывается ≤ 300 мс, затем кэш |
| `EmptyState` (search / cart / favorites / customers / transactions / no-photo / parked / notifications; иллюстрация 120–160 с `brandAccent` (текст на нём — только `onBrandAccent #1B1F2A`, R0 §17.5), `h3`, `body` `textSecondary`, кнопка) | fade-in 200 (ANIM-022) | — | — | кольцо на кнопке | — | — | вариант error — см. `ErrorState` | — | =def | «Нет сохранённых данных» + «Подключитесь к сети» |
| `ErrorState` (inline / banner / full-screen; `errorContainer`, иконка `error`, текст, «Повторить») | — | — | — | кольцо на «Повторить» | — | «Повторить» → `loading` кнопки | =def: причина по `code` problem+json (`ONEC_UNAVAILABLE`, `INTERNAL`, таймаут), `requestId` мелким `caption` для поддержки | — | — | офлайн-вариант = `OfflineBanner`, не `ErrorState` |
| `ConfirmDialog` (default / destructive; 400, `r-lg`, `elev3`, `overlay`) | заголовок `h3`, текст `body`, кнопки «Отмена» (outlined) + CTA (primary / danger filled) | кнопки hover | кнопки pressed | фокус по умолчанию — на **безопасной** кнопке («Отмена») | — | CTA `loading`, «Отмена» disabled | вариант «Требуется обновление» (HTTP 426): без «Отмена», не закрывается `Esc`/«Назад»/тапом по `overlay`, иконка `warning`, «Обновить» primary L (§8 п. 1) | — | — | CTA disabled, если действие требует сети |
| `StepUpDialog` (вариант `self`: причина, `PinField` / «Код по SMS», «Отмена»; кнопка биометрии в R1 **скрыта** — биометрия без криптопривязки как второй фактор не принимается `[РЕШЕНИЕ: ядро §19.3]`; на compact — нижний лист `AppBottomSheet` (ANIM-025), на medium+ — диалог; вариант `supervisor` (PIN/OTP старшего на чужом устройстве) — **R2**, в требования R1 не входит: в R1 подтверждение старшего — в его собственной сессии по 10 CASH-007 `[РЕШЕНИЕ: ядро §19.2]`) | открыт scale .96→1 250 (ANIM-023); compact — slide-up (ANIM-025) | — | — | фокус в `PinField` | «Код по SMS» disabled при `OTP_RATE_LIMITED` | проверка `/auth/step-up` — точки пульсируют | неверный PIN — shake, «Осталось попыток: {n}» (лимит — **5** попыток до `PIN_LOCKED`; `{n}` — только из `attemptsLeft` ответа сервера, клиент попытки не считает `[РЕШЕНИЕ: ядро §19.3]`); `423 PIN_LOCKED` → только «Код по SMS»/вход по номеру; `OTP_LOCKED` | — | — | PIN доступен офлайн? — **нет**: `stepUpToken` выдаёт сервер → диалог сообщает «Требуется сеть» `[РЕШЕНИЕ: D-48; Q-241]` |
| `AppBottomSheet` (modal / persistent / `side`; `r-lg` 16 сверху, ручка 32×4 `border`, bg `surface`; `side` — панель справа, `r-lg` слева, ширина 320 (overlay-корзина, medium) / **400** (детали и формы, medium) / **480** (детали и формы, expanded) `[РЕШЕНИЕ: ядро §19.4]`; на expanded нижние листы не используются — только `side` 480) | slide-up 250 standardDecelerate, overlay fade (ANIM-025); `side` — slide-in справа на ширину панели, закрытие slide-out 200 standardAccelerate (ANIM-025) | — | ручка — перетаскивание | — | — | содержимое — скелетон | — | — | — | =def |
| `AppSnackbar` (info / success / error; с действием «Отменить»/«Открыть»; `elev2`, 4 с / 8 с с действием) | bg `inverseSurface #1B1F2A`, fg `onInverseSurface #FFFFFF` `[РЕШЕНИЕ: ядро §18.2 п. 15]`; иконка по типу; появление ANIM-027 | — | — | кольцо на действии | — | — | error: иконка `error` на `inverseSurface` (контраст иконки ≥ 3:1 проверяет 03; при недостатке — светлый вариант иконки) `[ТИПОВО]` | — | — | «Нет сети» как info |
| `AppTabs` (fixed / scrollable; `label` 14/500) | fg `textSecondary` | fg `textPrimary` | — | кольцо | fg `disabledText` (вкладка без прав — скрыта, не disabled) | — | вкладка с ошибкой — точка `error` | fg `textPrimary` 600 + подчёркивание `primary` 2 (скользит 200, ANIM-017); оранжевая линия — только доп. признак (R4 §3.6) | — | =def |
| `Mascot` (Rive, 6 состояний; 160–200) | `idle`: дыхание 2 с loop (ANIM-002) | — | — | `typing`: взгляд на поле (ANIM-003) | — | `verifying`: «думает» 1,2 с loop (ANIM-004), таймаут 15 с → error | `error`: покачивание 400 мс (ANIM-011) + shake поля (ANIM-012) → через 1,5 с `retry` (ANIM-026) | `success`: улыбка → галочка `success` (ANIM-005) ≤ 900 мс → переход | — | `idle` + подпись «Нет сети» в поле; визуальный слой независим от результата (D-40) |
| `SplashLogo` (знак + wordmark; `brandAccent`/логотип по Q-006; текст на `brandAccent` — `onBrandAccent #1B1F2A`, R0 §17.5) | scale .92→1, opacity 0→1 **600 мс** (`splashLogo`, R0 §8.4; 03 ANIM-001), кривая `ds.motion.curve.emphasized`, wordmark 120–600 мс (ANIM-001; переход на первый экран — ANIM-028); максимум 1,2 с; reduce-motion — crossfade ≤ 80 мс без scale | — | — | — | — | `AppProgress` linear 2 lp `primary` при проверке > 400 мс | ошибка проверки → переход на SCR-01 без задержки | — | — | =def (сессия по локальному сроку) |
| `AdaptiveScaffold` (compact / medium / expanded) | раскладка по классу окна (`responsive-spec.md` §1) | — | — | — | — | — | — | — | — | вставляет `OfflineBanner` под шапкой |
| `BottomNavBar` (64, 5 пунктов, иконка 24 + `caption` 12) | fg `textSecondary`, иконки outlined | — | ripple `surfacePressed` | кольцо | пункт без прав — скрыт | — | — | иконка filled `primary` + пилюля `primaryContainer` 64×32 (ANIM-017) | — | =def |
| `NavigationRailApp` (72 / 96 с подписями) | как BottomNavBar вертикально | tooltip | ripple | кольцо | скрыт | — | — | как BottomNavBar | — | =def |
| `TopAppBarPos` (desktop: логотип, бургер, `SearchBar`, часы/дата `tabularFigures`, профиль «Абдулла ▾ Продавец», `NotificationBell`; mobile: знак + иконки) `[ПОДТВЕРЖДЕНО: макет]` | bg `surface`, `elev1` | — | — | — | — | `SyncIndicator` syncing | `SyncIndicator` error | — | — | `SyncIndicator` offline + `OfflineBanner` ниже |

Итого в матрице §2.1–§2.5: 59 компонентов R0 §8.5 в 62 строках (все позиции ядра; `AppButton` — 6 строк-вариантов: primary, secondary/tonal, outlined, text, danger, success; `FilterPanel`/`FilterSheet` и `SkeletonBox`/`SkeletonList` — по одной строке на пару). Ещё 18 компонентов R0 §17.5 — в матрице §9.1 (итого 77 канонических компонентов).


### 2.6. Отображение enum-статусов в `StatusChip`

Каждый статус показывается «семейство цвета + иконка + текст» (A11Y-004, ST-10). Иконки — Material Symbols Rounded (D-17). Русские тексты — рабочие; окончательные строки и ключи ARB (`status_<enum>_<value>`) утверждает 03 — владелец ключей ARB (R0 §18.1); 02 использует их `[ТИПОВО]`. Семейства: **neutral** — `surfaceVariant`/`textSecondary`; **info** — `infoContainer`/`info`; **success** — `successContainer`/`success`; **warning** — `warningContainer`/`warning`; **error** — `errorContainer`/`error`.

| Enum (источник) | Значение | Семейство | Иконка | Текст RU | Где показывается |
|---|---|---|---|---|---|
| `order_status` (D-20) | `draft` | neutral | `edit_note` | «Черновик» | технический статус внутри создания (R0 §17.2); в списках обычно не виден |
| `order_status` | `submitting` | info | `sync` (вращение, ANIM-021) | «Отправляется в 1С» | SCR-22, SCR-24, SCR-25 |
| `order_status` | `submit_failed` | error | `error` | «Ошибка отправки в 1С» | SCR-24, SCR-25, SCR-44 |
| `order_status` | `pending_approval` | info | `hourglass_top` | «На согласовании» | SCR-22, SCR-24, SCR-25 |
| `order_status` | `awaiting_payment` | warning | `payments` | «Ожидает оплаты» | SCR-24, SCR-25, SCR-30 |
| `order_status` | `approved` | success | `check_circle` | «Согласован» | SCR-24, SCR-25 |
| `order_status` | `awaiting_shipment` | info | `inventory_2` | «Ожидает отгрузки» | SCR-24, SCR-25 |
| `order_status` | `shipped` | success | `local_shipping` | «Отгружен» | SCR-24, SCR-25, SCR-33 |
| `order_status` | `partially_returned` | warning | `assignment_return` | «Частичный возврат» | SCR-24, SCR-25, SCR-33 |
| `order_status` | `closed` | neutral | `task_alt` | «Закрыт» | SCR-24, SCR-25, SCR-33 |
| `order_status` | `cancelled` | neutral | `cancel` | «Отменён» | SCR-24, SCR-25 |
| `payment_status` (D-21) | `initiated` | neutral | `schedule` | «Создан» | SCR-24, SCR-37, SCR-38 |
| `payment_status` | `cash_pending` | warning | `payments` | «Ожидает наличных» | SCR-22, SCR-38 |
| `payment_status` | `qr_pending` | info | `qr_code` | «Формируется QR» | SCR-22, SCR-38 (`QrPanel`) |
| `payment_status` | `qr_shown` | info | `qr_code_2` | «Ожидаем оплату по QR» | SCR-22, SCR-38 (`QrPanel`) |
| `payment_status` | `qr_expired` | warning | `timer_off` | «QR истёк» | SCR-22, SCR-38 |
| `payment_status` | `manual_confirm` | warning | `fact_check` | «Ждёт ручного подтверждения» | SCR-22, SCR-38, SCR-37 |
| `payment_status` | `credit` | warning | `credit_score` | «В долг» | SCR-24, SCR-36, SCR-37 |
| `payment_status` | `received` | success | `check_circle` | «Оплачено» | SCR-22, SCR-24, SCR-36, SCR-37 |
| `payment_status` | `voided` | error | `block` | «Аннулирован» | SCR-24, SCR-36, SCR-37 |
| `payment_status` | `refunded` | neutral | `undo` | «Возвращён» | SCR-24, SCR-36, SCR-37 |
| `payments.review_reason` (атрибут, не статус; 07 §6.4, ядро §23 п.4) | `amount_mismatch` / `unknown_reference` / `no_webhook` / `late_payment` | warning (доп. чип рядом со статусом платежа) | `fact_check` | «Сумма не совпадает» / «Неизвестная ссылка платежа» / «Ожидает подтверждения по выписке» / «Оплата после истечения QR» | SCR-22, SCR-24, SCR-30 («Требуют разбора»), SCR-38, SCR-48 |
| `return_request_status` (R0 §6) | `draft` | neutral | `edit_note` | «Черновик» | SCR-39 |
| `return_request_status` | `submitted` | info | `send` | «Отправлена» | SCR-24, SCR-37, SCR-39 |
| `return_request_status` | `accepted` | success | `check` | «Принята» | SCR-24, SCR-37, SCR-39 |
| `return_request_status` | `rejected` | error | `do_not_disturb_on` | «Отклонена» | SCR-24, SCR-37, SCR-39 |
| `return_request_status` | `completed` | success | `task_alt` | «Оформлена в 1С» | SCR-24, SCR-37, SCR-39 |
| `sync_run_status` (R0 §6) | `queued` | neutral | `schedule` | «В очереди» | SCR-43 |
| `sync_run_status` | `running` | info | `sync` (вращение, ANIM-021) | «Выполняется» | SCR-43, `SyncIndicator` |
| `sync_run_status` | `success` | success | `cloud_done` | «Успешно» | SCR-43 |
| `sync_run_status` | `partial` | warning | `warning` | «Частично» | SCR-43, SCR-30 |
| `sync_run_status` | `failed` | error | `sync_problem` | «Ошибка» | SCR-43, SCR-30, SCR-44 |
| `outbox_status` (R0 §6) | `pending` / `sending` | info | `schedule` / `sync` | «В очереди» / «Отправляется» | SCR-43 (admin, вкладка Outbox) |
| `outbox_status` | `sent` | info | `outbox` | «Отправлено, ждём 1С» | SCR-43 |
| `outbox_status` | `confirmed` | success | `check_circle` | «Подтверждено 1С» | SCR-43 |
| `outbox_status` | `failed` / `dead` | error | `error` / `report` | «Ошибка (повтор)» / «Не доставлено» | SCR-43 («Повторить» у `failed`) |
| `user_status` (R0 §6) | `pending` / `pending_activation` | warning | `hourglass_empty` | «Ожидает» / «Ожидает активации» | SCR-45 |
| `user_status` | `active` | success | `check_circle` | «Активен» | SCR-45 |
| `user_status` | `blocked` | error | `lock` | «Заблокирован» | SCR-45 |
| `user_status` | `deleted` | neutral | `delete` | «Удалён» | SCR-45 |
| `cart_status` (R0 §6) | `active` / `parked` | info / neutral | `shopping_cart` / `pause_circle` | «Активная» / «Отложена» | SCR-20, SCR-23 |
| `cart_status` | `converted` / `cleared` | neutral | `task_alt` / `remove_shopping_cart` | «Оформлена» / «Очищена» | SCR-23 (история) |

Правила: (1) «Оплачено» — признак/сумма платежа, а не статус заказа (D-21): у заказа показываются два чипа — статус заказа и статус оплаты; (2) неизвестное значение enum (новое значение backend) — neutral + `help` + исходный код значения, без падения экрана `[ТИПОВО]`; (3) расширения enum по R0 §17.3 (`notification_kind` + `payment_status`/`return_status`) используют те же семейства, что и соответствующий статус; (4) `voided` для **полученного наличного** платежа в R1 не возникает: аннулирование полученного наличного платежа запрещено (исправление — документами 1С), действие «Аннулировать» у такого платежа не показывается `[РЕШЕНИЕ: ядро §19.2]`.

---

## 3. Анимации (ANIM) — соответствие R4 §7.2

Столбец ID — канонические ID из 03 §11.2 (владелец — 03, R0 §18.1); строки соответствуют R4 §7.2 #1…#20 (предварительные `ANIM-01…ANIM-20` — только в таблице соответствия §9.4). При расхождении длительностей действует 03 §11.2. Длительности — R0 §8.4; кривые — Flutter `Easing` (R4 §7.1). Кривые — токены `ds.motion.curve.{standard, standardDecelerate, standardAccelerate, emphasized}` (R0 §17.5). `reduceMotion` (оба флага Flutter + переключатель в SCR-42) → столбец «при reduce-motion»: по R0 §17.5 — только crossfade ≤ 80 мс или статичный кадр («мгновенно» = смена без анимации либо crossfade ≤ 80 мс).

| ID (03 §11.2) | Анимация | Компоненты | Длит./кривая (R0 §8.4) | При reduce-motion |
|---|---|---|---|---|
| ANIM-001 (+ ANIM-028) | Splash: появление логотипа | `SplashLogo` | `splashLogo 600` (R4: 500 emphasizedDecelerate; общий максимум 1,2 с) | crossfade ≤ 80 |
| ANIM-002 | Персонаж idle | `Mascot` | 2 с loop sine | статичный кадр |
| ANIM-003 | Персонаж typing | `Mascot` + `PhoneField`/`OtpField` focus | `mascotTransition 250` (R4: 200 standard) | статичный кадр «смотрит на поле» |
| ANIM-004 | Персонаж verifying | `Mascot`, `OtpField` loading | loop 1,2 с; таймаут 15 с → ANIM-011 | статичный кадр + «Проверяем…» |
| ANIM-005 | Персонаж success | `Mascot`, галочка `success` (`SuccessCheck`) | ≤ 900 мс (улыбка 200 → галочка scale 0→1 250 → переход 400) | `SuccessCheck` — crossfade ≤ 80 мс `[РЕШЕНИЕ: ядро §18.2 п. 15]` |
| ANIM-011 + ANIM-012 | Персонаж error + shake поля | `Mascot`, `OtpField`, `PinField`, `AppTextField` | 400 + 300; shake ±4 lp 1 раз | без shake, только цвет + текст |
| ANIM-026 | Персонаж retry | `Mascot` | 300 standard | мгновенно |
| ANIM-006 | Добавление в корзину (desktop) | `ProductCardGrid` (кнопка → степпер crossfade 200), бейдж `CartPanel` scale 1→1.25→1, `CartLine` slide-in 16 lp + fade 300 | `base 200` / `slow 300` | только число и fade строки |
| ANIM-006 (compact) + ANIM-027 | Добавление в корзину (телефон) | `CartFab` пульс, `AppSnackbar` «Добавлено · Открыть» | 200 | без пульса |
| ANIM-010 (+ ANIM-007) | Обновление количества / перекат суммы | `QuantityStepper`, `CartLine`, `CartSummary`, `PriceText` | 200 standard | crossfade ≤ 80 (без переката) |
| ANIM-008 | Удаление строки корзины | `CartLine` схлопывание + fade, `AppSnackbar` «Отменить» 5 с | 250 standardAccelerate | мгновенно |
| ANIM-013 (+ ANIM-014) | Скелетон-шиммер | `SkeletonBox`/`SkeletonList`, `ProductCardGrid` loading | 1,2 с loop linear; старт после 300 мс; через 10 с — прогресс | статичные блоки |
| ANIM-024 | Переходы экранов | `AdaptiveScaffold`, go_router transitions | compact: shared-axis X 24 lp + fade; medium/expanded: fade-through; `slow 300` standard | crossfade ≤ 80 |
| ANIM-023 + ANIM-025 | Диалог / bottom sheet | `AppBottomSheet`, `ConfirmDialog`, `StepUpDialog`, модальное окно SCR-21 | overlay fade + slide-up (compact) / scale .96→1 (expanded) 250 standardDecelerate; закрытие 200 accelerate | crossfade ≤ 80 |
| ANIM-015 | Hover / pressed | все интерактивные | `fast 150` | смена цвета без анимации (0) |
| ANIM-017 | Сегмент / таб / навигация | `ViewModeSegmented`, `AppTabs`, `BottomNavBar`, `NavigationRailApp` | индикатор скользит 200 standard | crossfade ≤ 80 (без скольжения) |
| ANIM-021 | Статус синхронизации | `SyncIndicator`, `StatusChip` submitting, `OfflineBanner` reconnecting | вращение loop 1 с; завершение — галочка 300 → текст | статичная иконка + текст |
| ANIM-018 | Переход шага оформления | `CheckoutStepper`, контент SCR-21 | fade-through 250; галочка scale-in | crossfade ≤ 80 |
| ANIM-022 + ANIM-019 | Пустое состояние | `EmptyState` (ANIM-022), баннеры `CartPanel`/`OfflineBanner`, `CartFab` (ANIM-019) | fade-in 200 | мгновенно |
| ANIM-029 | Видоискатель камеры: линия-подсказка (нет в R4 §7.2) `[РЕШЕНИЕ: ядро §19.4]` | рамка видоискателя SCR-17 (экранный элемент 02 §9 Часть B, SCR-17) | loop 1,5 с linear, ≤ 1 цикла/с (A11Y-018); ошибка камеры → остановка + `EmptyState` | статичная линия по центру рамки |
| ANIM-030 | Видоискатель камеры: подтверждение распознавания (нет в R4 §7.2) `[РЕШЕНИЕ: ядро §19.4]` | рамка видоискателя SCR-17 + haptic `selectionClick` | 300 мс standard: рамка → `success` 150 → обратно 150; не найден — рамка `error` 300 | смена цвета без анимации (`success`/`error` на 300 мс) |
| ANIM-R2-001 | Сканирование лица (R2, Q-003) | SCR-05 кольцо-прогресс | 300/сегмент | статичные подсказки |

Дополнительные микроанимации матрицы получили ID в 03 §11.2: `FavoriteToggle` — ANIM-009; `QrPanel` галочка оплаты — `SuccessCheck` ANIM-005; `OfflineBanner` back-online — ANIM-019; автоповтор удержания `QuantityStepper` — ANIM-007; раскрытие категории сайдбара — ANIM-016; раскрытие тела `OptionTile` — ANIM-020; видоискатель камеры SCR-17 — ANIM-029 (линия-подсказка) и ANIM-030 (подтверждение распознавания) `[РЕШЕНИЕ: ядро §19.4]`.

---

## 4. Таблица «компонент → экраны, где используется»

| Компонент | Экраны (`SCR-xx`, полные ID) | Примечание (сокращение NN = `SCR-NN`) |
|---|---|---|
| `AppButton` | все, кроме SCR-00 | primary CTA: 01, 02, 03, 04, 14, 20, 21, 22, 26, 38, 39; success: 21; danger: 24, 41, 45; outlined: 20, 21, 23 |
| `AppIconButton` | SCR-10…SCR-14, SCR-20, SCR-21, SCR-24, SCR-30, SCR-36, SCR-42, SCR-44, SCR-45 (шапка, крестики, сканер, очистка) | |
| `AppTextField` | SCR-03, SCR-13, SCR-21, SCR-26, SCR-38, SCR-39, SCR-42, SCR-45, SCR-46 | multiline со счётчиком: 21 (комментарий 0/200; адрес доставки — до **300** символов, 0/300 `[РЕШЕНИЕ: ядро §19.4]`; «Выбрать на карте» — R2, Q-178), 39 (причина) |
| `PhoneField` | SCR-01, SCR-03 (read-only), SCR-21 (телефон получателя), SCR-26, SCR-41 (смена номера), SCR-45 (приглашение) | |
| `OtpField` | SCR-02, SCR-90 (`StepUpDialog` «Код по SMS») | |
| `PinField` | SCR-04, SCR-08, SCR-42, SCR-90 (`StepUpDialog`) | |
| `SearchBar` | SCR-10, SCR-11, SCR-12, SCR-30, SCR-31, SCR-25, SCR-36, SCR-45, SCR-47; компактный — в `CustomerPicker` (SCR-21) | кнопка сканера — только 10/11/12/20 |
| `CategorySidebarItem` | SCR-10, SCR-11, SCR-12, SCR-13, SCR-14 (SB под панелью), SCR-40, SCR-50 (сайдбар expanded/large; колонка категорий medium) | синхронизировано со строкой «Сайдбар/панели» `responsive-spec.md` §3–§8 |
| `CategoryChip` | SCR-10, SCR-11, SCR-12, SCR-13, SCR-50 (compact/medium) | |
| `ProductCardGrid` | SCR-10, SCR-11, SCR-12, SCR-40, SCR-50 | |
| `ProductCardList` | SCR-10, SCR-11, SCR-12, SCR-40, SCR-50 (режим «Список», узкие контейнеры) | |
| `ProductCardCompact` | SCR-10, SCR-11, SCR-12 (режим «Компакт», POS) | |
| `ProductImage` | SCR-10…SCR-15, SCR-20, SCR-21 (состав), SCR-22, SCR-24, SCR-39 | |
| `PriceText` | SCR-10…SCR-16, SCR-20, SCR-21, SCR-22, SCR-24, SCR-33, SCR-34, SCR-36, SCR-37, SCR-38, SCR-48 | |
| `StockBadge` | SCR-10…SCR-15, SCR-20 (строки с конфликтом), SCR-40 | by-warehouse — 14: раскрывается в `WarehouseStockTable` (R0 §17.5, §9.2) |
| `UnitSelector` | SCR-14, SCR-15, SCR-16, SCR-20 | |
| `QuantityStepper` | SCR-10…SCR-12 (после добавления), SCR-14, SCR-15, SCR-20, SCR-39 | |
| `QuantityNumpadSheet` | SCR-16 (вызов из SCR-14, SCR-20, SCR-39) | |
| `VariantSelector` | SCR-14, SCR-15 | |
| `FavoriteToggle` | SCR-10…SCR-12, SCR-14, SCR-40 (товары); SCR-30, SCR-31, SCR-32 (клиенты — cashier/admin) | |
| `SortMenu` | SCR-10, SCR-11, SCR-12, SCR-25, SCR-36, SCR-40 | |
| `FilterPanel` / `FilterSheet` | SCR-13 (для SCR-10…SCR-12), SCR-25, SCR-36, SCR-43 (admin), SCR-47 | |
| `ViewModeSegmented` | SCR-10, SCR-11, SCR-12, SCR-40 | |
| `CartPanel` | SCR-20; постоянная панель на expanded/large: SCR-10, SCR-11, SCR-12, SCR-13, SCR-14, SCR-15, SCR-16, SCR-25, SCR-40, SCR-43 (staff), SCR-44; overlay на expanded: SCR-50; видна под overlay/SS (не интерактивна): SCR-08, SCR-21, SCR-22 (пуста), SCR-23, SCR-26, SCR-38, SCR-39 | по сводной матрице `responsive-spec.md` §10, столбец «CP на expanded»; на compact — панель-итог, на medium — overlay |
| `CartLine` | SCR-20, SCR-23 (compact), SCR-21 (состав, read-only), SCR-24 (read-only), SCR-39 (с чекбоксами) | |
| `CartSummary` | SCR-20, SCR-21, SCR-22, SCR-24, SCR-37 | |
| `DiscountInput` | SCR-20, SCR-21 (с правом) | |
| `CheckoutStepper` | SCR-21 | регистрация (SCR-03, SCR-04, SCR-06; 3 шага «Данные · Защита входа · Готово» + «Привязка» при SCR-06) — `RegistrationStepper` (R0 §17.5, §19.3; §9.2) |
| `PaymentMethodCard` | SCR-21 (оплата, получение — та же плитка), SCR-38 | |
| `CustomerPicker` | SCR-21, SCR-20 (строка «Клиент»), SCR-36, SCR-25 (фильтр по клиенту) | |
| `CustomerCard` | SCR-21, SCR-26 (найден в 1С), SCR-30, SCR-31, SCR-32, SCR-40 (вкладка «Клиенты»), SCR-06 | |
| `ReceivableBadge` | SCR-21 (мета клиента), SCR-24 (клиент заказа), SCR-30, SCR-31, SCR-32, SCR-34, SCR-48 | seller — без суммы (Q-017) |
| `TransactionRow` | SCR-25, SCR-30, SCR-33, SCR-36 | |
| `StatusChip` | SCR-20, SCR-22, SCR-23, SCR-24, SCR-25, SCR-30, SCR-33, SCR-34, SCR-35, SCR-36, SCR-37, SCR-38, SCR-39, SCR-43, SCR-44, SCR-45, SCR-48 | |
| `SyncIndicator` | шапка всех экранов оболочки (SCR-10…SCR-48), SCR-30 (блок), SCR-43 | |
| `OfflineBanner` | SCR-90 (поверх всех) | |
| `SkeletonBox` / `SkeletonList` | SCR-10…SCR-15, SCR-20, SCR-23…SCR-25, SCR-30…SCR-37, SCR-40, SCR-43…SCR-48 | |
| `EmptyState` | SCR-07, SCR-11, SCR-20, SCR-23, SCR-25, SCR-31, SCR-33, SCR-36, SCR-40, SCR-44, SCR-47, SCR-90 (вариант «нет данных офлайн») | |
| `ErrorState` | SCR-05, SCR-17, SCR-22 (QR), SCR-38, SCR-43, SCR-90 | |
| `ConfirmDialog` | SCR-03 (прерывание), SCR-04 (отказ от согласия/биометрии), SCR-06, SCR-20 (очистка; удаление строки по «−» на минимуме или вводу 0 — CART-003/012, R0 §19.4), SCR-21 (отмена), SCR-23 (удаление отложенной корзины — `DELETE /cart/parked/{id}`, R0 §19.2), SCR-24 (запрос отмены), SCR-26, SCR-38, SCR-39 (удаление черновика возврата — `DELETE /returns/{id}`, R0 §19.2), SCR-41 (выход), SCR-42 (сессии), SCR-43 (полная синхронизация), SCR-45 (в т. ч. однократный показ аварийного кода входа — 03 п. 9.66, ядро §23 п.8), SCR-46, SCR-90 (обновление) | |
| `StepUpDialog` | SCR-21 (скидка сверх лимита, долг), SCR-22, SCR-38 (ручное подтверждение QR), SCR-24 (отмена), SCR-34 (первый просмотр и повторно через 15 мин), SCR-39, SCR-41 (смена номера, logout-all), SCR-42 (PIN, биометрия), SCR-43 (`full`/`reconcile`, admin/owner), SCR-45 (роли, блокировка, чужие сессии, приглашения), SCR-46 (настройки, OTP/SMS), SCR-90; по R0 §19: SCR-24 (ручная привязка к документу 1С `POST /orders/{id}/onec-link` при `ORDER_MATCH_AMBIGUOUS`), разрешение конфликта привязки клиента (`customer.link.resolve`, admin), назначение ролей `owner` в ограниченном режиме SCR-45; по R0 §23: SCR-38 (ручное аннулирование неполученного платежа; при смене способа оплаты прежний платёж аннулирует система без step-up), SCR-39 («Согласовать»/«Отклонить», `return.approve`), SCR-45 («Выдать аварийный код входа», только admin) | R0 §3.3, §17.2, §19.1–§19.3, §23 п.3, п.8; только вариант `self` (вариант `supervisor` — R2, R0 §19.2); на compact — нижний лист |
| `AppBottomSheet` | SCR-13, SCR-15, SCR-16, SCR-20 (compact), SCR-44, SCR-48 (`DateRangePicker` compact), SCR-90 (`StepUpDialog` на compact); вариант `side`: overlay-корзина 320 (medium), боковые панели деталей/форм SCR-37, SCR-41, SCR-43, SCR-44, SCR-45, SCR-47 — 400 (medium) / 480 (expanded) | ширины `side` — R0 §19.4; состав экранов — 03 §9 и 02 |
| `AppSnackbar` | все экраны оболочки; SCR-02 (код отправлен), SCR-14, SCR-10 (добавлено), SCR-20 (удалено · отменить), SCR-43 (`SYNC_ALREADY_RUNNING`) | |
| `AppTabs` | SCR-14 (Описание · Характеристики · Склады), SCR-32 (История · Долги · Скидки · Заказы), SCR-40 (Товары · Клиенты), SCR-43 (admin), SCR-45 (Пользователи · Приглашения) | |
| `AppAvatar` | SCR-08, SCR-30, SCR-31, SCR-32, SCR-41, SCR-45, шапка `TopAppBarPos` | |
| `NotificationBell` | шапка всех экранов оболочки; SCR-44 | |
| `Mascot` | SCR-01, SCR-02 (и SCR-90 `StepUpDialog` «Код по SMS» — без персонажа) | D-40 |
| `SplashLogo` | SCR-00 | |
| `AdaptiveScaffold` | оболочка SCR-10…SCR-50 | |
| `BottomNavBar` | compact: SCR-10…SCR-50 (кроме root-экранов SCR-17, SCR-21, SCR-22, SCR-26*, SCR-38*, SCR-39* — на compact они полноэкранны без навигации) | * на compact эти экраны открываются полноэкранно |
| `NavigationRailApp` | medium: те же | |
| `TopAppBarPos` | expanded/large: SCR-10…SCR-50; mobile-вариант: compact/medium | |
| `QrPanel` | SCR-22, SCR-38 | |
| `PrintOptions` | SCR-21, SCR-22, SCR-24, SCR-38 | |
| `DateRangePicker` | SCR-25, SCR-33, SCR-36, SCR-47, SCR-48 | |
| `RoleBadge` | SCR-08, SCR-32 (тип клиента — аналог), SCR-41, SCR-45, SCR-46 | |
| `AuditRow` | SCR-37 (кратко), SCR-47 | |

Проверка полноты: каждый экран R0 §9 (кроме SCR-05 — R2) упоминается хотя бы в одной строке; каждый компонент R0 §8.5 присутствует в матрице §2 и в таблице §4; каждый компонент R0 §17.5 — в матрице §9.1 и таблице §9.2.

---

## 5. Открытые вопросы (ссылки на Q-…)

| Q | Влияние на матрицу |
|---|---|
| Q-006 | вариант B: `primary #FF8700` только с тёмным `onPrimary #1B1F2A`, `primaryText #B04E00` для цен/ссылок, `warning #8A6A00`, `focus #1F5FA8` (R4 §3.3) — строки `AppButton`, `PriceText`, `StatusChip`, `AppTabs`; тёмная тема — R2 |
| Q-009 | `SearchBar` loading при HID-буфере; состояние `ScanButton` «недоступно» без камеры |
| Q-014 | `QrPanel` — автоматический `received` по вебхуку vs ручное подтверждение (step-up) |
| Q-015 | `DiscountInput` error-порог «Макс. N %» по ролям |
| Q-017 | `ReceivableBadge` для seller — без суммы |
| Q-019 | `PrintOptions` — состав документов, превью — канонический `DocumentPreview` (R0 §17.5; матрица §9.1) |
| Q-021 | `UnitSelector`, `QuantityStepper` — кратность/упаковки из 1С |
| Q-026 | `CustomerPicker` empty = «Розничный покупатель» |
| Q-035 | стиль `Mascot` (плоский/нейтральный), бюджет Rive |
| Q-204 | **закрыт решением ядра v1.4** (R0 §19.2): `SortMenu` каталога и поиска — дополнительно `available:desc`, `sku:asc` (§2.2) |
| Q-221 | **закрыт решением ядра v1.4** (R0 §19.2): `ReceivableBadge` — действие «Обновить» через `POST /customers/{id}/receivables/refresh` (§2.4) |
| Q-215 | `DateRangePicker` журналов — значения периода по умолчанию (максимум 366 дней задан R0 §19.4) |

---

## 6. Трассировка на исходные требования

| Элемент | SRC / D / R |
|---|---|
| Единый набор компонентов, состояний, анимаций (§2, §3) | SRC-A-049, SRC-E-100 (дизайн-система), SRC-F-012 (состояния экранов) |
| Токены цвета/типографики | D-16, D-17, R0 §8.1–8.2, R4 §3.2, §4.2 |
| Правила состояний (§1) | R4 §6 (столбцы D/H/P/F/Dis/L/E/S), §3.4 (контраст, дальтонизм), A11Y-001…008 |
| Анимации (§3) | R4 §7.1–7.2, R0 §8.4, D-40; SRC-B-070…078 (персонаж), SRC-B-135 (анимация успешной регистрации) |
| Персонаж 6 состояний | D-40; SRC-B-069b, SRC-B-071…077 |
| Поиск: debounce, пустой результат, сканер | D-31, D-42; SRC-C-008, SRC-C-009, SRC-C-010 |
| Карточка товара: артикул, остаток, статус, кнопка/степпер | SRC-C-026…034 |
| Корзина: счётчик, количество, предупреждения, очистка с подтверждением | SRC-C-060…072 |
| Оплата, QR, печать | D-21, D-26, D-27; макет `IMG_7090.PNG` |
| Долг: источник 1С, устаревание, fail-closed | D-24; SRC-C-104…112 |
| Индикаторы синхронизации, офлайн | D-29, D-32; SRC-B-054, SRC-C-091 |
| Избранное на сервере, оптимистичное переключение | D-32; SRC-C-100…103 |
| Step-up для критических операций | R0 §3.3; SRC-C-117, SRC-C-118a |
| Таблица «компонент → экраны» (§4) | R0 §9, §8.5; SRC-F-004 |

---

## 7. Замечания к ядру

1. **Снято ядром v1.2.** `WarehouseStockTable` и `OptionTile` — канонические компоненты R0 §17.5 (отдельные строки §9.1; пометок `[НОВОЕ ИМЯ]` у них нет); `ReceiptPreview` (R4 §6 #54) → `DocumentPreview`, `ProgressIndicator` (R4 §6 #50) → `AppProgress` (R0 §17.5); `EmployeeTile` (R4 §6 #45) — R2 (Q-002).
2. R0 §8.4 задаёт `splashLogo 600` и `mascotTransition 250`, R4 §7.2 — 500 и 200 соответственно; матрица использует значения ядра, расхождение отмечено в §3.
3. **Снято ядром v1.3.** Токены инверсного фона добавлены: `inverseSurface #1B1F2A`, `onInverseSurface #FFFFFF` (R0 §18.2 п. 15) — строки `AppSnackbar` §2.5 и `AppTooltip` §9.1 переведены на них `[РЕШЕНИЕ: ядро §18.2 п. 15]`.
4. `StepUpDialog` офлайн: `stepUpToken` выдаёт сервер (`/auth/step-up`), поэтому критические операции недоступны офлайн — снято решением D-48 (§9.7).
5. Вариант `AppButton` **success** отсутствует в перечне вариантов R0 §8.5 (primary/secondary/tonal/outlined/text/danger), но канонизирован в 03 §9.1 («`success` — заливка `success`/`onSuccess`»), а R0 §17.5 объявляет 03 §9 канонической спецификацией компонентов. Документ использует его со ссылкой на 03 §9.1; просьба дополнить перечень вариантов в R0 §8.5.


---

## 8. Дополнения по ядру v1.1 (R0 §16)

1. **`ConfirmDialog` / `ErrorState` — вариант «Требуется обновление»** (R0 §16 п. 4): триггер — HTTP 426 `APP_UPDATE_REQUIRED` + `X-Min-App-Version`. Состояние `error` у `ConfirmDialog` в этом варианте — **без кнопки отмены** и без закрытия по тапу на затемнение `overlay`/`Esc`/«Назад»; иконка `ds.color.warning` (не `error` — это не сбой, а ожидаемое действие), заголовок `ds.text.title` (18/26/600), текст версий `ds.text.body` (14/20) + `textSecondary`, кнопка «Обновить» `AppButton` primary L; анимация появления — ANIM-023 (диалог, 03 §11.2; предв. ANIM-14: scale .96→1 на expanded / slide-up на compact, 250 мс; закрытие 200 мс). Состояние `offline` неприменимо (426 приходит только при сети). Вариант **внесён** в строку `ConfirmDialog` §2.5 (столбец error); в §4 `ConfirmDialog` уже указан для SCR-90 (обновление).
2. **Нумерация вопросов** (R0 §16 п. 9): документ не вводит новых `Q-`; ссылки §5 — только на вопросы ядра R0 §12; предложения §7 (новые компоненты `ReceiptPreview`, `ProgressIndicator`, токен `inverseSurface`) нумерует владелец 03 в диапазоне `Q-108…` либо `14_OPEN_QUESTIONS.md`.
3. Прочие пункты R0 §16 на состояния компонентов не влияют.

---

## 9. Дополнения по ядру v1.2 (R0 §17)

Ядро v1.2 (R0 §17, 2026-10-18) объявлено приоритетным над текстом документов. Уточнения **внесены прямо** в строки §1–§4 (токены `onError`/`onSuccess`/`iconButtonPressed`, ST-11 и столбец reduce-motion §3, `SplashLogo` 600 мс, `QrPanel` → `SuccessCheck`, `StockBadge` → `WarehouseStockTable`, `CheckoutStepper` → `RegistrationStepper`, `ConfirmDialog` «Требуется обновление»); таблицы §9.3, §9.5–§9.7 — журнал со ссылками на исправленные строки, §9.1–§9.2 и §9.4 — самостоятельные таблицы. Каноническая спецификация компонентов — `03_UX_UI_DESIGN_SYSTEM.md` §9 (R0 §17.5); матрица этого раздела — сводное представление той же информации в столбцах §2 (`03` §9.10, §9.15, §9.18, §9.30, §9.33, §9.63–§9.66, §13.6; там, где `03` не задаёт состояние, — `[ТИПОВО]` по общим правилам ST-1…ST-12 §1).

### 9.1. Матрица «компонент × состояние» для компонентов R0 §17.5

Состав R0 §8.5 расширен 18 компонентами (R0 §17.5): `CategoryTile`, `ImageGallery`, `WarehouseStockTable`, `CartFab`, `OptionTile`, `AppProgress`, `AppTooltip`, `AppCheckbox`, `AppRadio`, `AppSwitch`, `AppDropdown`, `AppDivider`, `AppBadge`, `AppSectionHeader`, `AppListTile`, `DocumentPreview`, `SuccessCheck`, `RegistrationStepper`. Итого канонических компонентов — **77** (59 из R0 §8.5 + 18 из R0 §17.5). ID анимаций в этой таблице — окончательные из `03` §11.2 (`ANIM-0NN`, см. §9.4).

| Компонент (варианты) | default | hover | pressed | focused | disabled | loading | error | selected | empty | offline |
|---|---|---|---|---|---|---|---|---|---|---|
| `CategoryTile` (icon / image; 96×96…160×120, `r-md`, иконка 32 `primary` в круге 56 `primaryContainer`, название `label` 13/500 в 2 строки, счётчик `caption` `textSecondary`) | bg `surface`, bd `border` | `elev1` (ANIM-015) | scale .98, bg `surfacePressed` | кольцо `focus` | — | скелетон-карточка (ANIM-013) | изображение группы не загрузилось → иконка-fallback (никогда чужое изображение, D-30) | текущая категория — bd `primary` 2 | нет подкатегорий → `EmptyState` (вариант categories) | =def; счётчики из кэша drift с подписью возраста в заголовке экрана |
| `ImageGallery` (single / multi; основное фото `ProductImage` full, индикатор «2 / 5» `caption` в пилюле `overlay`, лента миниатюр 56) | фото + лента, bg `surfaceVariant` | стрелки ←/→ появляются (только указатель, expanded) | тап → полноэкранный просмотр (bg `textPrimary`, кнопки `onPrimary`) | кольцо на миниатюре; ←/→ листают | — | скелетон основного фото + 3 миниатюры (ANIM-013); фото проявляется fade 200 (ANIM-014) | заглушка «Нет фото» на позиции, лента остаётся | миниатюра — рамка `primary` 2 | одна заглушка 1:1, лента скрыта | из кэша изображений; отсутствующее в кэше — заглушка с `cloud_off` |
| `WarehouseStockTable` (seller: Склад · Доступно; cashier: + Резерв · Остаток; customer: «Доступно: да/нет»; строки 40, числа `body` tnum вправо) | заголовок bg `surfaceVariant` `label` 13/500; итог «Все склады · 24» `body` 600; подпись «Обновлено 09:41» `caption` `textSecondary` | строка `surfaceHover` | — | — | — | 3 скелетон-строки (ANIM-013) | inline «Не удалось получить остатки · Повторить» (`error` + иконка) | полоса 3 `primary` — склад продажи по умолчанию | «Нет данных по складам» `caption` | снимок `synced_at` с подписью возраста; при превышении порога свежести (NFR-SYNC-001) — подпись `warning` |
| `CartFab` (только compact, опционально medium; 56, `r-md`, `elev2`, иконка `shopping_cart` + бейдж, «Корзина», итог `bodyLg` 700 tnum «16 007,50 сом», шеврон) | bg `primary`, fg `onPrimary` | — | bg `primaryPressed` | кольцо `focus`, `Enter` открывает SCR-20 | — | — | есть изменения цен/остатков: иконка `warning` (на `onPrimary`) слева от итога | — | скрыт при пустой корзине (slide/fade 200, ANIM-019) | =def; итог по локальной корзине с пометкой «по кэшу» в SCR-20 (не на самой панели) |
| `OptionTile` (radio / check / withBody; ≥ 72, `r-md`, паддинг 16; иконка 24, заголовок `body` 600, подпись `caption`) | bg `surface`, bd `border` 1 | bg `surfaceHover`, bd `borderStrong` | bg `surfacePressed` | кольцо; `Space` — выбор, стрелки — между плитками | bg `disabledBg`, fg `disabledText` + подпись причины («Доставка недоступна для этого клиента») | — | bd `error` + «Выберите способ получения» (при попытке продолжить) | bd `primary` 2 + bg `primaryContainer` + радио/`check_circle` `primary` (три признака); `withBody` раскрывает поля (ANIM-020, 200) | — | =def; способы, требующие сети, — как `PaymentMethodCard` offline (§2.3) |
| `AppProgress` (circular 16/20/24/48; linear 2/4; stepped; determinate / indeterminate) | скрыт; показ после задержки 300 мс, минимум 300 мс на экране | — | — | — | — | это и есть loading: `primary` на треке `primaryContainer` (на заливке — `onPrimary`); вращение 1 с loop | > 10 с — текст «Долгая загрузка…» + «Повторить»/«Отменить»; при сбое заменяется `ErrorState` | — | — | не запускается для операций «только онлайн» — вместо него `OfflineBanner` и disabled-кнопка |
| `AppTooltip` (text / rich; фон `inverseSurface #1B1F2A`, текст `caption` 12/500 `onInverseSurface #FFFFFF` `[РЕШЕНИЕ: ядро §18.2 п. 15]`, `r-sm`, `elev2`, ширина ≤ 280) | скрыт | показ через 500 мс (700 мс — названия в карточках), скрытие через 100 мс | тач: долгое нажатие 500 мс → показ, скрытие через 1,5 с | показ при фокусе с клавиатуры через 500 мс; `Esc` закрывает | — | — | — | — | не показывается при пустом тексте | =def (содержимое локальное); никогда не единственный носитель информации |
| `AppCheckbox` (20, `r-xs`, bd `borderStrong` 2; подпись `body` 14; indeterminate) | bd `borderStrong` | ореол 40 `surfaceVariant` | ореол `iconButtonPressed #E2E6EC` | кольцо `focus`; `Space` | bd/заливка `disabledText`, подпись `textSecondary` | — | bd `error` 2 + «Нужно согласие» `caption` `error` (SCR-04, `CONSENT_REQUIRED` 422) | заливка `primary` + галочка `onPrimary` 14 | — | =def; значение уходит при отправке формы (согласие SCR-04 — только онлайн) |
| `AppRadio` (20, bd `borderStrong` 2; используется внутри `OptionTile` и списков) | bd `borderStrong` | ореол `surfaceVariant` | ореол `iconButtonPressed` | кольцо; стрелки — между пунктами | `disabledText` | — | bd `error` 2 + подпись | кольцо `primary` 2 + точка `primary` 10 | — | =def |
| `AppSwitch` (52×32; настройки SCR-42) | трек `borderStrong`, ползунок `surface` | ореол `surfaceVariant` | ореол `iconButtonPressed` | кольцо; `Space` | трек `disabledBg`, ползунок `disabledText` | ползунок → спиннер 16 (ожидание сервера; повторные тапы игнорируются); для «Биометрия» — сначала `StepUpDialog` (R0 §17.2) | откат положения + `AppSnackbar` error «Не удалось сохранить» | трек `primary`, ползунок `onPrimary` + иконка | — | переключатели, требующие сервера (биометрия, PIN), — disabled «Нужна сеть»; локальные («Уменьшить анимации», плотность) — работают |
| `AppDropdown` (стиль `SortMenu` + подпись как у `AppTextField`) | bg `surface`, bd `borderStrong`, значение `body` | bd `textSecondary` | — | bd `primary` 2 | bg `disabledBg`, fg `disabledText` | спиннер 16 в суффиксе (варианты грузятся) | bd `error` 2 + helper `caption` `error` | пункт меню с check `primary`, bg `primaryContainer` | placeholder `textTertiary` («Выберите…») | =def; варианты из кэша (например, интервалы доставки `app_settings.delivery_slots`) |
| `AppDivider` (`border` 1 lp, отступы `space4` = 16) | `border` | — | — | — | — | — | — | — | — | =def |
| `AppBadge` (dot / number; `error` + `micro` 11/600 `onError`, 1–2 цифры, «99+») | bg `error`, fg `onError` | — | — | — | скрыт | — | — | — | 0 → скрыт | значение из кэша; не обнуляется офлайн |
| `AppSectionHeader` (`label` 600 `textSecondary` + действие справа: «Недавние товары · Очистить») | текст `textSecondary`; действие — `AppButton` text | действие — подчёркивание | действие — fg `primaryPressed` | кольцо на действии | действие fg `disabledText` (например «Очистить» при пустом списке) | — | — | — | заголовок остаётся, под ним — `EmptyState` | действие, требующее сервера (`DELETE /catalog/products/recent`), уходит в outbox как тип `recent.clear` `[РЕШЕНИЕ: ядро §19.4]`; заголовок =def |
| `AppListTile` (48/56; иконка, заголовок, подзаголовок, trailing: шеврон / `AppSwitch` / значение) | bg `surface`, разделитель `AppDivider` | bg `surfaceHover` | bg `surfacePressed` | кольцо внутри строки | fg `disabledText`, trailing скрыт | trailing → спиннер 16 | подзаголовок `error` + иконка | bg `primaryContainer` + полоса 3 `primary` (активная секция в 2-колоночной раскладке SCR-42/46) | — | строки, требующие сервера, — disabled с подписью «Нужна сеть» |
| `DocumentPreview` (под-компонент `PrintOptions`; A4 — по ширине, 80 мм — колонка 302 lp на `surfaceVariant`; цифры Inter tnum) | превью PDF + панель «Печать · Сохранить · Закрыть» | кнопки панели hover | — | кольцо на кнопках | «Печать» disabled без настроенного принтера (SCR-42) | скелетон страницы + «Формируем PDF…» | «Документ не сформирован» + «Повторить»; создание заказа не блокируется (D-27) | — | накладная — «Печатается из 1С» (D-27), превью нет | «Печать после подключения» (PDF формирует backend) |
| `SuccessCheck` (круг `success` + галочка `onSuccess`; Rive-артборд или Lottie, `03` §13.6) | скрыт | — | — | — | — | — | — | показ: круг scale 0→1 250 мс `emphasized` + галочка (ANIM-005), всего ≤ 900 мс; затем экран выполняет переход; reduce-motion — crossfade ≤ 80 мс `[РЕШЕНИЕ: ядро §18.2 п. 15]` | — | не показывается (успех приходит только с сервера, D-40) |
| `RegistrationStepper` (3 шага «Данные · Защита входа · Готово»: SCR-03 «Данные» → SCR-04 «Защита входа» → шаг «Готово» на SCR-04; при показе SCR-06 — 4 шага «Данные · Защита входа · Привязка · Готово» `[РЕШЕНИЕ: ядро §19.3]`; compact — «Шаг 2 из 3 · Защита входа» + `AppProgress` linear, medium+ — horizontal; FACE-SCAN — R2) | done — круг `success` + ✓ `onSuccess`; active — пилюля `surfaceVariant` с цифрой; upcoming — круг bd `border`, fg `textTertiary` | — | — | кольцо на пройденном шаге (возврат на SCR-03 без потери введённых данных) | непройденный шаг не кликабелен; на шаге «Готово» возврат к предыдущим шагам недоступен (03 §9) | — | шаг с ошибкой — круг `error` + «!» | active | — | =def; переход на шаг 2 и `/registration/complete` — только онлайн |

### 9.2. Таблица «компонент → экраны» для компонентов R0 §17.5

| Компонент | Экраны (`SCR-xx`, полные ID) | Примечание |
|---|---|---|
| `CategoryTile` | SCR-12 (compact/medium), SCR-50 (compact/medium) | 3 колонки на compact, 4–5 на medium; на expanded не используется — там `CategorySidebarItem` |
| `ImageGallery` | SCR-14 | compact — лента под фото; expanded — вертикальная лента 64 слева от фото |
| `WarehouseStockTable` | SCR-14 (секция панели на expanded / `AppBottomSheet` на compact по тапу на `StockBadge` by-warehouse) | заменяет «`StockBadge` by-warehouse» из §2.2 как отдельный компонент; customer — только «Доступно: да/нет» |
| `CartFab` | SCR-10, SCR-11, SCR-12, SCR-14, SCR-40, SCR-50 (compact; на medium — опционально при закрытой overlay-панели) | скрыт на SCR-20/SCR-21 и при пустой корзине; это «панель-итог 56» из `responsive-spec.md` |
| `OptionTile` | SCR-21 (получение: Самовывоз / Доставка; получатель: Клиент / Другой человек), SCR-14 и SCR-15 (выбор упаковки — вариант `check`/`radio`) | основа `PaymentMethodCard` (SCR-21, SCR-38) |
| `AppProgress` | SCR-00 (linear 2 lp), SCR-02 и SCR-08 (circular в кнопке), SCR-10 (первичная загрузка каталога, stepped), SCR-22 (формирование QR), SCR-43 (прогон синхронизации), SCR-05 (R2, stepped) | > 10 с — «Долгая загрузка…» |
| `AppTooltip` | SCR-10, SCR-11, SCR-12 (полные названия в карточках, expanded), SCR-14 (остатки), SCR-30 и SCR-32 (`ReceivableBadge` «Данные 1С на 09:41»), SCR-43 (по сущностям), SCR-45 (права роли), шапка `TopAppBarPos` (`SyncIndicator`, иконки) | на compact — долгое нажатие |
| `AppCheckbox` | SCR-04 (согласия), SCR-13 (фильтры), SCR-21 (`PrintOptions`), SCR-39 (позиции возврата), SCR-45 (массовый выбор) | ошибка `CONSENT_REQUIRED` — SCR-04 |
| `AppRadio` | SCR-21 (внутри `OptionTile` и `PaymentMethodCard`), SCR-38, SCR-39 (причина возврата `return_reason`) | |
| `AppSwitch` | SCR-42 (биометрия, «Уменьшить анимации», сканер: добавлять в корзину по скану — настройка `scan_adds_to_cart` в `user_profiles.settings`; по умолчанию вкл. для `cashier`, выкл. для `seller` `[РЕШЕНИЕ: ядро §19.4]`), SCR-46 (флаги `app_settings`; `CUSTOMER_SELF_SERVICE` — только env, переключатель read-only (disabled с подписью) `[РЕШЕНИЕ: ядро §19.2]`) | биометрия и PIN — со `StepUpDialog` (R0 §17.2) |
| `AppDropdown` | SCR-21 (желаемое время «Сегодня» / «с 14:00 до 18:00»), SCR-26, SCR-39 (причина), SCR-42 (язык, принтер), SCR-45 (роль), SCR-46 | |
| `AppDivider` | все экраны со списками и секциями (SCR-10…SCR-48) | |
| `AppBadge` | `NotificationBell` (шапка всех экранов оболочки), `CartPanel` и `CartFab` (счётчик), `BottomNavBar`/`NavigationRailApp` (корзина, уведомления), SCR-13 (счётчик активных фильтров) | |
| `AppSectionHeader` | SCR-10 (сайдбар: «Категории товаров», «Недавние товары · Очистить»), SCR-14, SCR-21 (колонки), SCR-30 (секции дашборда), SCR-42, SCR-46 | `[ПОДТВЕРЖДЕНО: макет]` — «Недавние товары · Очистить» |
| `AppListTile` | SCR-41, SCR-42, SCR-44, SCR-46 (навигация секций), SCR-43 (строки сущностей на compact) | |
| `DocumentPreview` | SCR-21 (после создания — счёт), SCR-22, SCR-24, SCR-38 (товарный чек — после получения оплаты; квитанция об оплате долга без заказа — `GET /payments/{id}/documents/receipt.pdf`, PAY-043 `[РЕШЕНИЕ: ядро §19.2]`) | только счёт, нефискальный товарный чек и квитанция об оплате долга (D-26, D-27; R0 §19.4 — порядок печати) |
| `SuccessCheck` | SCR-02 (успешный вход), SCR-04 (регистрация завершена), SCR-22 и SCR-38 (`QrPanel` → `received`), SCR-90 (`StepUpDialog` — успешный step-up) | заменяет «галочку по образцу ANIM-005» в строке `QrPanel` §2.3 |
| `RegistrationStepper` | SCR-03, SCR-04, SCR-06 (шаг «Привязка», только при показе SCR-06) (SCR-05 — R2) | заменяет «compact-вариант `CheckoutStepper`» в строке §4; 3 шага (+ «Привязка») — R0 §19.3 |

Строки §4 `CheckoutStepper` и `StockBadge` приведены к этой таблице: на регистрации используется `RegistrationStepper`, остатки по складам — `WarehouseStockTable`.

### 9.3. Уточнения токенов и общих правил (R0 §17.5)

| № | Уточнение | Где действует в матрице | Источник |
|---|---|---|---|
| V12-1 | `iconButtonPressed #E2E6EC` — каноническое имя токена (строка `AppIconButton` §2.1 и правило ST-2 §1 используют это имя); тот же токен — ореол pressed у `AppCheckbox`/`AppRadio`/`AppSwitch` | §2.1 `AppIconButton`; §9.1 | R0 §17.5 |
| V12-2 | `onSuccess #FFFFFF` — текст/иконка на `success` (кнопка «Создать заказ и показать QR», `CheckoutStepper`/`RegistrationStepper` done, `SuccessCheck`); `onError #FFFFFF` — на `error` (`AppButton` danger filled, `AppBadge`, бейдж `NotificationBell`). Значения совпадают с `onPrimary`, поэтому визуально матрица §2 не меняется — строки §2 переведены на имена `onSuccess`/`onError` | §2.1 `AppButton` danger/success; §2.3 `CheckoutStepper`, `CartPanel` (бейдж); §2.4 `NotificationBell` | R0 §17.5 |
| V12-3 | `onBrandAccent #1B1F2A` — текст на `brandAccent #FF8700` (только бренд-элементы: `SplashLogo`, иллюстрации `EmptyState`, персонаж); белый текст на оранжевом не используется | §2.5 `SplashLogo`, `EmptyState` | R0 §17.5, D-16 |
| V12-4 | Вариант B (Q-006): `primaryText #B04E00` — для цен (`PriceText`), ссылок (`AppButton` text) и выбранных вкладок, вместо `primary` (оранжевый на белом не проходит AA для текста) | §2.1, §2.2 `PriceText`, §2.5 `AppTabs` (только при выборе B) | R0 §17.5, Q-006 |
| V12-5 | Кривые — токены `ds.motion.curve.standard`, `.standardDecelerate`, `.standardAccelerate`, `.emphasized`; в §3 и §2 названия кривых («standardDecelerate», «emphasized») читаются как эти токены | §2, §3 | R0 §17.5 |
| V12-6 | `reduceMotion` = **crossfade ≤ 80 мс или статичный кадр** (а не «0 мс»): правило ST-11 и столбец «при reduce-motion» §3 приведены к этому правилу — мгновенные смены допускаются, но где нужен сигнал о смене состояния (сегменты, табы, перекат суммы, `SuccessCheck`), используется crossfade ≤ 80 мс | §1 ST-11, §3 | R0 §17.5 |
| V12-7 | Плотность — `DsDensity {standard, compact}` (в §1 и `responsive-spec.md` §1.2 — «density standard/compact»); тач-цель 48 lp не уменьшается ни в одной плотности | все строки с размерами 48/56 и 40/48 | R0 §17.5, D-18 |
| V12-8 | Радиус `r-xl 20` (`ds.radius.xl`) — **только** карточка входа/регистрации SCR-01…SCR-04 и SCR-08 (на medium+); SCR-06, SCR-07 — `r-lg 16` (R0 §18.2 п. 15); в остальных компонентах не применяется (диалоги и листы — `r-lg 16`) | §2.5 `ConfirmDialog`, `StepUpDialog`, `AppBottomSheet` — без изменений | R0 §17.5, §18.2 п. 15 |
| V12-9 | Тени — по R0 §8.3 (`elev0…elev3`), приоритет над R4 §5.4; матрица использует только `elev0…elev3` | §2 | R0 §17.5 |
| V12-10 | Брейкпоинт `ds.breakpoint.large ≥ 1600` — каноническое имя (в `responsive-spec.md` R-4 имена порогов были предложены как `[НОВОЕ ИМЯ]`) | `AdaptiveScaffold` §2.5 | R0 §17.5 |
| V12-11 | Rive: state machine `MascotAuth`, входы `isTyping`, `isChecking`, `success`, `error`, `retry`, `lookX`, `lookY`, `reduceMotion`, `blink` (вход `blink` входит в `MascotAuth` — R0 §18.2 п. 15) — строка `Mascot` §2.5: `typing` = `isTyping`, `verifying` = `isChecking`, `reduceMotion` → статичные кадры; имена методов `MascotController` — канон 03 §17.6 | §2.5 `Mascot` | R0 §17.5, §18.2 п. 15, D-40 |
| V12-12 | Формат телефона: ввод и отображение **`+996 XXX XXX XXX`**, хранение и API — E.164 `+996XXXXXXXXX` (до ответа Q-112). Маска `PhoneField` в §2.1 приведена к этому формату; маска макета «+996 (___) ___-__-__» и пример «+996 (700) 123-45-67» в ТЗ не используются | §2.1 `PhoneField`, §2.4 `CustomerCard` (телефон в мете) | R0 §17.2 |
| V12-13 | Пример арифметики во всех состояниях `CartSummary`/`CartFab`: товары 16 850,00, скидка 5 % = 842,50, итого **16 007,50 сом**; суммы макета (−820 / 16 030) не используются | §2.3 `CartSummary`, §9.1 `CartFab` | R0 §17.2 |

### 9.4. Окончательные ID анимаций (`03` §11.2) ↔ предварительные ID этого документа

`03_UX_UI_DESIGN_SYSTEM.md` выпустил реестр `ANIM-001…ANIM-028` (+ `ANIM-R2-001`, R0 §17.6). Предварительные `ANIM-01…ANIM-20` (= строки R4 §7.2), ранее стоявшие в ячейках §2–§3, соответствуют им так; с версии 1.4 в §1–§3 используются только окончательные ID (R0 §18.1, §18.2 п. 15), а эта таблица сохранена для трассировки:

| Предварительный ID (до версии 1.4) | Окончательный ID (`03` §11.2) | Комментарий |
|---|---|---|
| ANIM-01 Splash | ANIM-001 (+ ANIM-028 «Splash → первый экран») | |
| ANIM-02 Персонаж idle | ANIM-002 | |
| ANIM-03 Персонаж typing | ANIM-003 | |
| ANIM-04 Персонаж verifying | ANIM-004 | |
| ANIM-05 Персонаж success | ANIM-005 (`SuccessCheck`) | |
| ANIM-06 Персонаж error + shake | ANIM-011 (персонаж) + ANIM-012 (shake поля/кнопки) | разделены в 03 |
| ANIM-07 Персонаж retry | ANIM-026 | |
| ANIM-08 Добавление в корзину (desktop) | ANIM-006 | |
| ANIM-09 Добавление в корзину (телефон) | ANIM-006 (ветка compact: пульс `CartFab`) + ANIM-027 (снекбар «Добавлено · Открыть») | |
| ANIM-10 Перекат количества/суммы | ANIM-010 (+ ANIM-007 автоповтор `QuantityStepper`) | автоповтор — «доп. микроанимация» §3 получила ID |
| ANIM-11 Удаление строки корзины | ANIM-008 | |
| ANIM-12 Скелетон-шиммер | ANIM-013 (+ ANIM-014 появление фото) | |
| ANIM-13 Переходы экранов | ANIM-024 | |
| ANIM-14 Диалог / bottom sheet | ANIM-023 (диалог) + ANIM-025 (bottom sheet / side sheet) | разделены в 03 |
| ANIM-15 Hover / pressed | ANIM-015 | |
| ANIM-16 Сегмент / таб / навигация | ANIM-017 | |
| ANIM-17 Синхронизация | ANIM-021 | |
| ANIM-18 Шаг оформления | ANIM-018 | |
| ANIM-19 Пустое состояние / баннеры | ANIM-022 (пустое состояние) + ANIM-019 (баннеры, `CartFab`) | |
| ANIM-20 Сканирование лица (R2) | ANIM-R2-001 | вне R1, Q-003 |
| «доп.» `FavoriteToggle` scale | ANIM-009 | |
| — (нет в §3) | ANIM-016 (сайдбар: раскрытие категории / сворачивание), ANIM-020 (раскрытие тела `OptionTile`) | новые в 03 |
| — (нет в R4 §7.2; в 02 — SCR-17-ANIM-A / SCR-17-ANIM-B) | ANIM-029 (видоискатель: линия-подсказка), ANIM-030 (видоискатель: подтверждение распознавания) | новые в 03 по R0 §19.4; строки добавлены в §3 |

При расхождении длительностей между §3 и `03` §11.2 действует `03` (правило приоритета R0 > 03 > 02 > visual/, README §3).

### 9.5. Новые коды ошибок и заголовки (R0 §17.4) → состояния компонентов

| Код / заголовок | HTTP | Компонент и состояние | Экраны |
|---|---|---|---|
| `PIN_INVALID` | 401 | `PinField` error: shake (ANIM-012) + «Неверный PIN. Осталось попыток: {n}» (`attemptsLeft`); клиент **не** вызывает `/auth/refresh` (R0 §18.2 п. 5) | SCR-08, SCR-42, SCR-90 (`StepUpDialog`) |
| `UNLOCK_REQUIRED` | 401 | сессия не отозвана: открывается SCR-08 в режиме overlay (`PinField` / кнопка биометрии), проверка `POST /auth/unlock` (refresh + PIN или биометрия с криптопривязкой); состояние экрана под overlay сохраняется (R0 §18.2 п. 5) | SCR-08 (overlay поверх экранов оболочки) |
| `PIN_LOCKED` | 423 | `PinField` disabled + «PIN заблокирован. Войдите по номеру телефона»; `StepUpDialog` — остаётся только «Код по SMS» | SCR-08, SCR-90 |
| `CONSENT_REQUIRED` | 422 | `AppCheckbox` error (bd `error` 2 + «Нужно согласие»), фокус на чекбоксе | SCR-04 |
| `CUSTOMER_NOT_IDENTIFIED` | 422 | `CustomerPicker` error: «Для продажи в долг выберите клиента» (системный «Розничный покупатель» не допускается для `credit`); `PaymentMethodCard` «долг» — подпись причины | SCR-21, SCR-38 |
| `CART_EMPTY` | 422 | `CartPanel` empty (`EmptyState` cart); кнопка «Создать заказ» disabled; при гонке — `AppSnackbar` error и обновление корзины | SCR-20, SCR-21 |
| `UNAUTHENTICATED`, `TOKEN_STALE` | 401 | компонентов не меняют: тихий `/auth/refresh` и повтор запроса; при неуспехе — переход по guard G-1 (`navigation.md` §14) | все |
| `DEVICE_MISMATCH` | 409 | `ConfirmDialog` (без «Отмена») «Сессия привязана к другому устройству» → вход по номеру; на SCR-02 — ответ `/auth/otp/verify` (R0 §18.2 п. 7): `OtpField` error без shake + тот же диалог | SCR-90, SCR-02 |
| `APP_READ_ONLY` | 503 | баннер под шапкой по анатомии `OfflineBanner` (40 lp) в палитре `infoContainer`/`info`, иконка `lock_clock`, текст «Режим только просмотра: операции временно недоступны» `[ТИПОВО]`; все CTA записи (`AppButton` «Создать заказ», «Принять оплату», «Оформить возврат», «+ Новый клиент», «Сохранить» в админке) — disabled с этой подсказкой; просмотр работает | SCR-90 (поверх всех экранов оболочки) |
| `STALE_DATA` (предупреждение, не ошибка) + `X-Data-As-Of` | 200 | `CartSummary` — подпись `caption` `warning` «Проверено по данным 1С на 09:41»; `PaymentMethodCard` «долг» — disabled (продажа в долг fail-closed, D-24, R0 §17.2 D-29); `StockBadge`/`PriceText` — подпись возраста из `X-Data-As-Of` | SCR-20, SCR-21, SCR-14 |
| `APP_UPDATE_REQUIRED` + `X-Min-App-Version` | 426 | без изменений относительно §8 п. 1 | SCR-90 |
| `RECOMMENDED_APP_VERSION` (D-46, мягкое обновление; заголовок ответа `X-Recommended-App-Version` для платформы из `X-Platform`, R0 §18.2 п. 12) | — | `AppSnackbar` info с действием «Обновить» (8 с), не чаще 1 раза за запуск; не блокирует работу; на SCR-21/SCR-22/SCR-38 не показывается (не отвлекать при оплате) `[ТИПОВО]` | все экраны оболочки |
| `PAYLOAD_TOO_LARGE` 413, `UNSUPPORTED_MEDIA_TYPE` 415, `METHOD_NOT_ALLOWED` 405 | — | `AppSnackbar` error с `requestId` (`caption`) — технические ошибки, пользователь не может их исправить | все |

### 9.6. Изменения по правам и step-up (R0 §17.2) → состояния компонентов

- **`StepUpDialog` — новые точки вызова** (R0 §17.2): установка/смена PIN и включение/выключение биометрии (SCR-42, `AppSwitch` loading → `StepUpDialog`), отзыв чужих сессий и сброс PIN пользователя (SCR-45), создание/отзыв приглашений (SCR-45), изменение настроек приложения/OTP/SMS (SCR-46), запуск `full`/`reconcile` синхронизации (SCR-43, admin/owner). Строка `StepUpDialog` §4 дополнена SCR-42 и SCR-43 (внесено). Срок `stepUpToken` — 15 мин; детализация долга (SCR-34) — повторный step-up, если с последнего прошло > 15 мин.
- **SCR-43**: `AppButton` «Обновить остатки / цены / статусы» (`incremental` для `stock`, `prices`, `order_status`) — для `senior_seller` без step-up; «Полная синхронизация» / «Сверка» — только `admin`/`owner`, со `StepUpDialog`; для остальных ролей кнопки скрыты (не disabled — ST-4 «вкладка без прав скрыта»).
- **Разделение обязанностей** (R0 §17.2, D-15): у `admin` и `owner` нет кассовых операций — на SCR-24/SCR-30/SCR-34 кнопки «Принять оплату» для них **скрыты**; `PaymentMethodCard`, `QrPanel` в режиме приёма оплаты им не показываются (матрица ролей — `screen-map.md` §5 и §11).
- **Оплата/показ QR** допускаются для заказа в статусах `submitting`, `pending_approval`, `approved` (R0 §17.2) и также `awaiting_payment` `[РЕШЕНИЕ: ядро §19.4]`: в остальных статусах `AppButton` «Принять оплату»/«Показать QR» на SCR-24 скрыта, а `StatusChip` показывает статус заказа без действия.
- **SCR-08 в двух режимах** (R0 §17.2): `PinField` и `AppAvatar` используются одинаково в полноэкранном режиме (холодный старт) и в overlay idle-блокировки поверх сохранённого экрана (`overlay` + `ConfirmDialog`-анимация ANIM-023); состояния `PinField` §2.1 не меняются, `PIN_LOCKED` в overlay ведёт на SCR-01 без потери черновика корзины (локальная таблица drift `cart_draft`/`cart_items_draft`, R0 §18.2 п. 1; имя `cart_drafts` не используется).
- **Роли на экранах** (R0 §18.2 п. 11): на SCR-38 `PaymentMethodCard`, `QrPanel` и `AppButton` «Принять оплату» показываются только `cashier` и `senior_seller` (у `admin` — скрыты, D-15); SCR-21 доступен `seller`, `cashier`, `senior_seller`, `admin` и условно `customer` (флаг `CUSTOMER_SELF_SERVICE`); `owner` на SCR-39 — только просмотр заявок (элементы ввода read-only, CTA отправки скрыта — ST-4 «без прав скрыто»); `senior_seller` видит «Повторить» у элемента outbox своего магазина (`POST /sync/outbox/{id}/retry`) — это не запуск синхронизации; для `admin` «Повторить» — **без** `StepUpDialog` `[РЕШЕНИЕ: ядро §19.4]`; `owner` на SCR-45/SCR-46 — ограниченный режим (просмотр пользователей, назначение ролей со `StepUpDialog`, отзыв сессий; прочие CTA скрыты) `[РЕШЕНИЕ: ядро §19.1]`.
- **Ядро v1.4 — прочие точки, влияющие на состояния** (R0 §19.2–§19.4): `StepUpDialog` — только вариант `self` (вариант `supervisor` — **R2**, R0 §19.2), PIN 5 попыток, кнопка биометрии скрыта, на compact — нижний лист; `customer.link.resolve` и ручная привязка заказа к 1С (`POST /orders/{id}/onec-link`) — со `StepUpDialog`; `OtpField` на SCR-02 — по «SMS не пришло» статус доставки берётся из `GET /auth/otp/challenges/{challengeId}` (без ПДн) `[РЕШЕНИЕ: ядро §19.2]`; SCR-08 телефон пользователя не показывает и не предзаполняет (R0 §19.3); блокировка при возврате из фона — 5 мин, idle — 30 мин (открывается SCR-08 overlay, R0 §19.3); `ConfirmDialog` — удаление строки корзины по «−»/0, отложенной корзины и черновика возврата (§4).
- **Вне R1 (R2, R0 §19.2)** — компоненты этого документа их состояний не содержат: `StepUpDialog.supervisor`, экспорт CSV (Q-217), «пометить ошибку синхронизации решённой» и пауза сущности (Q-219), объединение корзин (CART-032), правка контактов клиента `PATCH /customers/{id}/contacts`, SMS-подтверждение клиента (CUST-013), «Выбрать на карте» для адреса (Q-178).
- **PIN на сервере** (D-48): строка `PinField` §2.1 уже приведена к этому правилу (офлайн — disabled, Q-241); то же для `StepUpDialog` — офлайн-проверка PIN вне R1, строка §2.5 «`[ТИПОВО]`» читается как `[РЕШЕНИЕ: D-48]`.

### 9.7. Статус замечаний §7 после ядра v1.2

| Замечание §7 | Статус |
|---|---|
| п. 1 (`WarehouseStockTable`, `OptionTile`, `ReceiptPreview`, `ProgressIndicator` вне R0 §8.5) | **снято**: `WarehouseStockTable` и `OptionTile` — канонические (R0 §17.5); `ReceiptPreview` → `DocumentPreview`; `ProgressIndicator` → `AppProgress`; `EmployeeTile` остаётся R2 (Q-002) |
| п. 2 (`splashLogo 600` vs R4 500; `mascotTransition 250` vs 200) | действует значение ядра; в `03` §11.2 ANIM-001 — 600 мс |
| п. 3 (токен инверсного фона для `AppSnackbar`/`AppTooltip`) | **снято ядром v1.3**: `inverseSurface #1B1F2A` / `onInverseSurface #FFFFFF` (R0 §18.2 п. 15) — строки `AppSnackbar` §2.5 и `AppTooltip` §9.1 переведены; полноэкранная `ImageGallery` сохраняет фон `textPrimary` по 03 |
| п. 4 (`StepUpDialog` офлайн) | **снято** решением D-48 (PIN проверяется на сервере; офлайн-разблокировка вне R1, Q-241) |

Новых `Q-` раздел не вводит (R0 §16 п. 9); ссылки — только на вопросы ядра (Q-002, Q-006, Q-008, Q-112, Q-241 и др.).

---

## 10. Журнал сверки с ядром (v1.2, v1.3, v1.4, v1.8)

| Пункт ядра | Что изменено | Где |
|---|---|---|
| R0 §17.5 — 18 новых компонентов | Подтверждены строки матрицы и экранов для `CategoryTile`, `ImageGallery`, `WarehouseStockTable`, `CartFab`, `OptionTile`, `AppProgress`, `AppTooltip`, `AppCheckbox`, `AppRadio`, `AppSwitch`, `AppDropdown`, `AppDivider`, `AppBadge`, `AppSectionHeader`, `AppListTile`, `DocumentPreview`, `SuccessCheck`, `RegistrationStepper` (состояния по `03` §9); итог «77 компонентов» добавлен в краткое содержание и под §2.5 | Краткое содержание; §2.5 (итоговая строка); §9.1; §9.2 |
| R0 §17.5 — 18 новых компонентов (перекрёстные ссылки) | `StockBadge` by-warehouse → `WarehouseStockTable`; регистрация → `RegistrationStepper` вместо compact-`CheckoutStepper`; Q-019 → `DocumentPreview`; замечание §7 п. 1 отмечено как снятое; проверка полноты расширена на §9.1/§9.2 | §4 (`StockBadge`, `CheckoutStepper`, проверка полноты); §5 (Q-019); §7 п. 1 |
| R0 §17.5 — `iconButtonPressed #E2E6EC` | Добавлен в правило pressed для иконок-кнопок и ореола контролов; формулировка V12-1 исправлена | §1 ST-2; §9.3 V12-1 |
| R0 §17.5 — `onSuccess`, `onError` | `AppButton` success → `onSuccess`; `AppButton` danger (filled) → `onError`; `CheckoutStepper` done → `onSuccess`; бейджи `NotificationBell` и `CartPanel` → `AppBadge` с `onError`; V12-2 приведён к факту замены | §2.1; §2.3; §2.4; §9.3 V12-2 |
| R0 §17.5 — `onBrandAccent #1B1F2A` | Текст на `brandAccent` — только `onBrandAccent` | §2.5 `EmptyState`, `SplashLogo` |
| R0 §17.5 — `reduceMotion` = crossfade ≤ 80 мс или статичный кадр | Правило ST-11 и краткое содержание переписаны (вместо «0 мс»); столбец «при reduce-motion» §3: кроссфейд 150 / fade 150 / fade 100 / fade → crossfade ≤ 80; сегменты, перекат суммы, шаги — crossfade ≤ 80; V12-6 приведён к факту замены | Краткое содержание; §1 ST-11; §3 (вводный абзац, ANIM-01, -05, -10, -13, -14, -15, -16, -18); §9.3 V12-6 |
| R0 §17.5 — кривые `ds.motion.curve.*` | Имена кривых в ST-11 и §3 даны как токены | §1 ST-11; §3 (вводный абзац) |
| R0 §17.5 — `DsDensity`, `r-xl 20`, тени `elev0…3`, `ds.breakpoint.large`, Rive `MascotAuth`, вариант B `primaryText` | Без изменений — уже учтено ранее | §9.3 V12-4, V12-7…V12-11 |
| R0 §17.2 — SCR-08 в двух режимах | Добавлен пункт о `PinField` в полноэкранном и overlay-режимах | §9.6 |
| R0 §17.2 — формат телефона, пример арифметики 16 007,50, step-up, D-15, статусы для QR | Без изменений — уже учтено ранее | §2.1 `PhoneField`; §2.3 `CartSummary`; §9.3 V12-12, V12-13; §9.6 |
| R0 §17.1 D-46, D-48; §17.4 коды ошибок | Без изменений — уже учтено ранее | §2.1 `PinField`; §9.5; §9.6 |
| R0 §17.6 — `ANIM-R2-`, диапазоны `Q-` | Без изменений — уже учтено ранее (§9.4; новых `Q-` нет) | §9.4; §9.7 |
| Шапка документа | Версия 1.2, дата, входные материалы дополнены R0 §16, §17 | Шапка |
| R0 §18.2 п. 15 — токены `inverseSurface #1B1F2A` / `onInverseSurface #FFFFFF` | `AppSnackbar`: bg `inverseSurface`, fg `onInverseSurface` (вместо `textPrimary`/`surface`, метка `[ТИПОВО]` → `[РЕШЕНИЕ: ядро §18.2 п. 15]`); `AppTooltip`: фон `inverseSurface`, текст `onInverseSurface` (вместо `textPrimary`/`onPrimary`); замечание §7 п. 3 и §9.7 п. 3 — сняты | §2.5 `AppSnackbar`; §9.1 `AppTooltip`; §7 п. 3; §9.7 |
| R0 §18.1 (03 — владелец ID `ANIM-0NN`) + §18.2 п. 15 | Предварительные `ANIM-01…ANIM-20` в ячейках §1–§3 заменены на канонические `ANIM-0NN` из 03 §11.2 по таблице §9.4 (в т. ч. ANIM-06 → ANIM-011/ANIM-012, ANIM-14 → ANIM-023/ANIM-025, ANIM-16 → ANIM-017, ANIM-17 → ANIM-021, ANIM-19 → ANIM-022/ANIM-019); столбец ID §3 — канонический; доп. микроанимации получили ID (ANIM-007, ANIM-009, ANIM-016, ANIM-019, ANIM-020); длительности `FavoriteToggle`, `StepUpDialog`, `CategoryChip`, автоповтора `QuantityStepper` — по 03; §9.4 оставлена как таблица трассировки | Краткое содержание; §1 ST-5, ST-6, сокращения; §2.1–§2.6; §3; §9.2 `SuccessCheck`; §9.4 |
| R0 §18.2 п. 15 — `SuccessCheck` при reduce-motion — crossfade ≤ 80 мс | Вариант «статичный кадр» убран | §3 ANIM-005; §9.1 `SuccessCheck` |
| R0 §18.2 п. 15 — пространства `ds.space.1…10`, `ds.radius.{xs…full}`, `ds.elevation.{0…3}`; `r-xl 20` — SCR-01…SCR-04, SCR-08; SCR-06/07 — `r-lg 16`; `blink`, `MascotController` | Соответствие коротких имён каноническим пространствам — в сокращениях §1; V12-8 дополнен SCR-06/SCR-07; V12-11 — ссылка на `blink` и 03 §17.6 | §1 (сокращения); §9.3 V12-8, V12-11 |
| R0 §18.1 — ключи ARB (владелец 03) | Ключи `status_<enum>_<value>` утверждает 03 (а не 02) | §2.6 |
| R0 §18.2 п. 1 — локальная схема drift | `cart_drafts` → `cart_draft`/`cart_items_draft` | §9.6 (SCR-08) |
| R0 §18.1 — ID анимаций (вне §2–§3) | `ConfirmDialog` «Требуется обновление»: ANIM-14 → ANIM-023 | §8 п. 1 |
| R0 §18.2 п. 5 — `POST /auth/unlock`, `UNLOCK_REQUIRED`, `PIN_INVALID` без refresh | `PinField` loading: `/auth/unlock` на SCR-08; `PIN_INVALID` — без `/auth/refresh`; новая строка `UNLOCK_REQUIRED` | §2.1 `PinField`; §9.5 |
| R0 §18.2 п. 7 — `DEVICE_MISMATCH` в `/auth/otp/verify` | Строка `DEVICE_MISMATCH` дополнена SCR-02 | §9.5 |
| R0 §18.2 п. 11 — роли на SCR-38, SCR-21, SCR-39 (owner — просмотр), retry outbox `senior_seller` | Добавлен пункт о видимости компонентов по ролям | §9.6 |
| R0 §18.2 п. 12 — заголовок `X-Recommended-App-Version` | Строка мягкого обновления дополнена заголовком | §9.5 |
| R0 §18.2 пп. 2–4, 6, 8–10, 13, 14, 16 | Без изменений — на состояния компонентов не влияют | — |
| Шапка документа (v1.3 ядра) | Версия 1.4; входные материалы дополнены R0 §18; в краткое содержание добавлен пункт о ядре v1.3 | Шапка; Краткое содержание |
| R0 §19.1 — 02 единственный канонический текст; части 02a…02e — черновики в `source/02_parts_drafts/` | Пометка «в работе — файл ещё не выпущен» у 02 заменена; ссылки на экраны — разделы 02 §9 «Часть A…E» (ссылок на `02_screens/…` в документе не было) | Шапка («Связанные документы»); §3 ANIM-029 |
| R0 §19.4 — `QuantityStepper`: «−» на минимуме = удаление строки с подтверждением (CART-003/012); debounce 500 мс (INV-043); неизвестный остаток — добавление запрещено (INV-052) | Столбец disabled: «−» в корзине не disabled → `ConfirmDialog` destructive; вне корзины — disabled; loading: debounce 500 мс, один `PUT /cart/items/{variantId}`; error: откат после ошибки сервера; `QuantityNumpadSheet` «OK» с 0 у строки корзины → подтверждение удаления; `ProductCardGrid`/`StockBadge` «Остаток неизвестен» — добавление запрещено; `ConfirmDialog` §4 дополнен SCR-20 (удаление строки) | §2.2 `QuantityStepper`, `QuantityNumpadSheet`, `ProductCardGrid`, `StockBadge`; §4 `ConfirmDialog` |
| R0 §19.3, §19.2 — `StepUpDialog`: 5 попыток PIN (счёт из ответа сервера), кнопка биометрии скрыта, compact — нижний лист; `supervisor` — R2 | Из анатомии убрана кнопка биометрии; добавлены лимит 5 попыток и `attemptsLeft` только с сервера; compact — `AppBottomSheet` (ANIM-025); вариант `supervisor` помечен «R2» и исключён из требований R1 (в R1 — CASH-007); §4 — новые точки вызова (`onec-link`, `customer.link.resolve`, owner SCR-45) и пометка «только `self`» | §2.5 `StepUpDialog`; §4 `StepUpDialog`, `AppBottomSheet`; §9.6 |
| R0 §19.2, §19.4 — `QrPanel`: «Обновить QR» на том же `payment_id` (PAY-025); показ в `awaiting_payment`; QR создаётся в `POST /orders` | default — статусы показа QR + `awaiting_payment`; loading — создание в составе `POST /orders`; error `qr_expired` — «Обновить QR» на том же `payment_id` (вместо «Сформировать заново»); §9.6 «Оплата/показ QR» дополнен `awaiting_payment` | §2.3 `QrPanel`; §9.6 |
| R0 §19.4 — `AppBottomSheet` вариант `side` 400 (medium) / 480 (expanded) | Вариант `side` добавлен в строку матрицы (ширины 320 / 400 / 480, анимация ANIM-025 slide-in/out) и в §4 (экраны боковых панелей, `StepUpDialog` на compact) | §2.5 `AppBottomSheet`; §4 `AppBottomSheet` |
| R0 §19.3 — `RegistrationStepper` 3 шага «Данные · Защита входа · Готово» (+ «Привязка» при SCR-06) | «Шаг 1 из 2 / из 3 при FACE-SCAN» заменено на 3 шага (+ 4-й «Привязка»); на шаге «Готово» возврат недоступен; SCR-06 добавлен в экраны | §9.1, §9.2 `RegistrationStepper`; §4 `CheckoutStepper` (примечание) |
| R0 §19.4 — ANIM-029/030 (видоискатель камеры) | Добавлены строки ANIM-029 и ANIM-030 в §3, в перечень доп. микроанимаций и в таблицу трассировки §9.4; диапазон ID в кратком содержании — `ANIM-001…ANIM-030` | Краткое содержание; §3; §9.4 |
| R0 §19.2 — Q-204 (сортировки `available:desc`, `sku:asc`), Q-221 (`POST /customers/{id}/receivables/refresh`) | `SortMenu` — новые сортировки; `ReceivableBadge` — действие «Обновить»; оба вопроса помечены «закрыт решением ядра v1.4» (Q-216, Q-218(б) в документе не упоминаются) | §2.2 `SortMenu`; §2.4 `ReceivableBadge`; §5 |
| R0 §19.4 — финансовые данные клиента офлайн не показываются; поиск клиента по ролям | `CustomerCard`, `ReceivableBadge` offline — долг/скидка не из кэша, только из памяти сессии; `CustomerPicker` — порог поиска (`cashier`+ — 4 цифры / 2 буквы, `seller` — полный номер или код) | §2.3 `CustomerPicker`; §2.4 `CustomerCard`, `ReceivableBadge` |
| R0 §19.4 — печать (чек после оплаты, накладная из 1С `available:false`, счёт после заказа); R0 §19.2 — квитанция `receipt.pdf` (PAY-043) | `PrintOptions` disabled — правила доступности документов; `DocumentPreview` — квитанция об оплате долга | §2.3 `PrintOptions`; §9.2 `DocumentPreview` |
| R0 §19.4 — избранное `PUT/DELETE /favorites/…`, звезда на карточках; `recent.clear`; период журналов ≤ 366 дней; адрес ≤ 300, «Выбрать на карте» — R2 | `FavoriteToggle` offline — пути API; `AppSectionHeader` offline — тип outbox `recent.clear`; `DateRangePicker` error — 366 дней (Q-215); `AppTextField` §4 — адрес 0/300 | §2.1 `DateRangePicker`; §2.2 `FavoriteToggle`; §9.1 `AppSectionHeader`; §4 `AppTextField`; §5 |
| R0 §19.4 — `scan_adds_to_cart` (cashier — в корзину, seller — карточка); R0 §19.2 — `CUSTOMER_SELF_SERVICE` только env | `AppSwitch` SCR-42 — настройка и значения по умолчанию; SCR-46 — флаг read-only | §9.2 `AppSwitch` |
| R0 §19.2 — `DELETE /cart/parked/{id}`, `DELETE /returns/{id}`; запрет аннулирования полученного наличного платежа; `GET /auth/otp/challenges/{challengeId}` | `ConfirmDialog` §4 — SCR-23, SCR-39; §2.6 правило (4) для `voided`; §9.6 — статус доставки SMS для `OtpField` | §2.6; §4 `ConfirmDialog`; §9.6 |
| R0 §19.1, §19.3, §19.4 — owner на SCR-45/46; retry outbox `admin` без step-up; SCR-08 без телефона; блокировки 5/30 мин | Пункты о видимости по ролям и SCR-08 дополнены | §9.6 |
| R0 §19.2 — перечень R2 | Добавлен пункт «Вне R1 (R2)»; в матрице R1 эти элементы отсутствуют | §9.6 |
| R0 §19.2 (прочие API/DTO), §19.4 (F9/F8, `PATCH /cart`, `checkout_draft`, `customer_type`, глифы иконок), §19.5 | Без изменений — на состояния компонентов этого документа не влияют (горячие клавиши — 03 A11Y-009 и `navigation.md`; глифы — 03); новых `Q-` документ не вводит | — |
| Шапка документа (v1.4 ядра) | Версия 1.5; входные материалы дополнены R0 §19; в краткое содержание добавлен пункт о ядре v1.4 | Шапка; Краткое содержание |
| R0 §23 п.1 (v1.8) — ручная привязка документа 1С | Проверено: `StepUpDialog` для `POST /orders/{id}/onec-link` на SCR-24 уже в §4 (по R0 §19); переходы outbox — у 07 §6.5; изменений нет | — |
| R0 §23 п.2 (v1.8) — момент проекции статуса заказа | Проверено: `StatusChip` показывает статус с сервера; изменений нет | — |
| R0 §23 п.3 (v1.8) — смена способа оплаты без step-up; `payment.void` | `QrPanel` — «Другой способ оплаты» без step-up из `qr_shown`, после ручного аннулирования из `qr_expired`/`manual_confirm`; `StepUpDialog` — SCR-38 ручное аннулирование | §2.3 `QrPanel`; §4 `StepUpDialog` |
| R0 §23 п.4 (v1.8) — `qr_expired → manual_confirm`, `review_reason` | Новая строка §2.6 `payments.review_reason` (4 значения, тексты — по общим ключам 03 п. 16.5); `QrPanel` — чип `late_payment` | §2.3 `QrPanel`; §2.6 |
| R0 §23 п.5 (v1.8) — `CUSTOMER_NOT_IDENTIFIED`, `credit_not_allowed` | `PaymentMethodCard` disabled — подпись по `creditReason` | §2.3 `PaymentMethodCard` |
| R0 §23 п.6–7 (v1.8) — `order.cancel.own`; блок «Ожидают оплаты» | Проверено: кодов прав и состава блоков дашборда в документе нет; `StatusChip` `awaiting_payment` на SCR-30 уже есть; изменений нет | — |
| R0 §23 п.8 (v1.8) — SCR-39 «Согласовать»/«Отклонить», SCR-45 аварийный код | `StepUpDialog` — SCR-39, SCR-45; `ConfirmDialog` — однократный показ кода на SCR-45 (03 п. 9.66) | §4 `StepUpDialog`, `ConfirmDialog` |
| R0 §23 пп. 9–10 (v1.8) — Q-168, Q-264; статистика | Проверено: документ этих вопросов и статистики не ведёт; изменений нет | — |
| Шапка документа (v1.8 ядра) | Версия 1.6; входные материалы дополнены R0 §23; заголовок журнала — «v1.2, v1.3, v1.4, v1.8» | Шапка; §10 |

### 10.1. Журнал доработки по замечаниям проверяющего (версия 1.3)

| Замечание | Что изменено | Где |
|---|---|---|
| `SplashLogo` 500 мс против ANIM-01 600 мс | строка `SplashLogo` — 600 мс (`splashLogo`, R0 §8.4; 03 ANIM-001), кривая `emphasized`, reduce-motion — crossfade ≤ 80 мс; linear progress → `AppProgress` | §2.5 |
| ST-11 «reduceMotion → 0 мс» | ST-11 и столбец «при reduce-motion» §3 — по R0 §17.5 (crossfade ≤ 80 мс или статичный кадр) | §1 ST-11; §3 |
| `AppButton` success без пометки; `onPrimary` на error/success | `success` — со ссылкой на 03 §9.1 и «Замечание к ядру» §7 п. 5; в строках danger/success — `onError`/`onSuccess` (и для спиннера) | §2.1; §7 п. 5 |
| `WarehouseStockTable` «нет в ядре» | §7 п. 1 переписан: компонент канонический (R0 §17.5) | §7 п. 1; §4 |
| `PUT /cart/discount` | `POST /cart/discount` (08 §4.7.5) | §2.1 `DiscountInput` |
| Наслоение «Дополнений» | правки v1.1/v1.2 внесены в §1–§4 (`ConfirmDialog` 426, `QrPanel` → `SuccessCheck`, `StepUpDialog` офлайн — D-48); §8–§9 — журнал | §2; §4; §8; §9 |
| Ссылки на документы | относительные ссылки в шапке; 02 помечен «в работе» | шапка |
