# Шаблоны печатных форм POS (RM-F-004)

Файлы `<вид>.<бумага>.json`: `invoice.a4`, `invoice.thermal80`, `receipt.a4`, `receipt.thermal80`. Рендер — `src/orders/documents/pdf/pdf-renderer.ts` (pdfkit, шрифт Inter из `../../fonts`). Шаблон меняется без изменения кода (Q-019); после замены файла перезапустите pos-api (шаблоны кэшируются на процесс). Структуру проверяет `parseTemplate` (ошибка → `500` только для этого запроса).

- `page` — ширина/высота в пунктах (1 мм = 2,8346 pt; A4 = 595,28 × 841,89; лента 80 мм = 226,77). Без `height` — одна страница по длине содержимого (чековая лента).
- `blocks` — по порядку: `text` (`text`, `size`, `bold`, `align`), `fields` (строки «подпись — значение», `labelWidth` — доля ширины), `table` (`rows` — путь к массиву модели, `columns[].width` — доли, сумма ≤ 1, `grid`), `each` (повтор вложенных блоков для массива), `rule` (линия, `dashed`), `spacer` (`height`).
- `when: "путь"` у блока или строки — выводить, только если значение непустое.
- Подстановки `{{путь}}` — поля модели `src/orders/documents/document-model.ts` (`invoiceModel`, `receiptModel`): `number`, `date`, `seller.*` (реквизиты из `app_settings.print.organization`), `customer.name|inn`, `items[]` (`lineNo`, `name`, `sku`, `quantity`, `unit`, `price`, `discount`, `sum`, `qtyPrice`), `totals.*`, `paid`, `remaining`, `payments[]` (`method`, `amount`, `received`, `change`, `receivedAt`), `cashier`, `copy`, `nonFiscalMark`, `nonFiscalTitle`.
- Каждая форма обязана содержать `{{nonFiscalMark}}` — «не является фискальным документом» (10 PRINT-010, D-26); слова «ККМ», «онлайн-касса», «фискальный чек» применительно к приложению не используются.
