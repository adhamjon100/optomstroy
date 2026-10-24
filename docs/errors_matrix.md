# Ошибки API → строка ARB → действие клиента

Выход RM-F-007 (13 §3.6). **Генерируется** `python -I -X utf8 scripts/gen_errors_matrix.py` из
`contracts/enums.json` (08 §2.4: `problemCodes`, `warning_code`), `pos-app/lib/core/error/error_mapper.dart`
(`UiErrorMapper`, `ErrorKeys`) и `pos-app/lib/l10n/app_ru.arb`; руками не править. Проверка актуальности —
`--check` (код 1 — файл устарел или код без строки ARB/действия). Действия — `ErrorAction` (08 §2.4
«Что делает клиент»).

## Ошибки (`Problem.code`)

| Код | HTTP | Ключ ARB | Текст (ru) | Действие |
|---|---|---|---|---|
| `VALIDATION_FAILED` | 400, 422 | `error_internal` | Не удалось выполнить. Повторите | `showFieldErrors` |
| `OTP_INVALID` | 422 | `auth_error_otp_invalid` | Неверный код. Осталось попыток: {n} | `none` |
| `OTP_EXPIRED` | 422 | `auth_error_otp_expired` | Код устарел. Запросите новый | `requestNewOtp` |
| `OTP_LOCKED` | 423 | `auth_error_otp_locked` | Попытки исчерпаны. Запросите новый код через {seconds} с | `retryAfter` |
| `OTP_RATE_LIMITED` | 429 | `auth_error_rate_limited` | Слишком много запросов. Подождите {seconds} с | `retryAfter` |
| `SMS_PROVIDER_ERROR` | 503 | `auth_error_sms_provider` | Не удалось отправить SMS. Попробуйте позже | `retryAfter` |
| `REGISTRATION_TOKEN_INVALID` | 401 | `reg_error_token_expired` | Время регистрации истекло. Подтвердите номер ещё раз — введённые данные сохранятся | `signIn` |
| `PHONE_ALREADY_REGISTERED` | 409 | `auth_entry_phone_registered` | Этот номер уже зарегистрирован. Войдите по коду из SMS | `signIn` |
| `UNAUTHENTICATED` | 401 | `auth_error_revoked` | Сессия завершена. Войдите снова | `refreshSession` |
| `TOKEN_STALE` | 401 | `global_permissions_changed` | Ваши права изменены администратором | `refreshSession` |
| `SESSION_REVOKED` | 401 | `auth_error_revoked` | Сессия завершена. Войдите снова | `signIn` |
| `DEVICE_MISMATCH` | 409 | `auth_error_device_mismatch` | Код запрошен с другого устройства. Запросите новый код | `requestNewOtp` |
| `STEP_UP_REQUIRED` | 403 | `error_step_up_required` | Подтвердите действие | `stepUp` |
| `FORBIDDEN` | 403 | `error_forbidden` | Недостаточно прав | `none` |
| `VERSION_CONFLICT` | 409 | `error_version_conflict` | Данные изменились на другом устройстве | `resolveVersionConflict` |
| `IDEMPOTENCY_KEY_REUSED` | 422 | `error_internal` | Не удалось выполнить. Повторите | `reportClientError` |
| `IDEMPOTENCY_IN_PROGRESS` | 409 | `error_idempotency_in_progress` | Операция уже выполняется | `retryAfter` |
| `PRICE_CHANGED` | 422 | `error_price_changed` | Цены изменились. Подтвердите новые цены | `confirmPrices` |
| `STOCK_INSUFFICIENT` | 422 | `error_stock_insufficient` | Недостаточно остатка: доступно {available} {unit} | `adjustQuantity` |
| `VARIANT_UNAVAILABLE` | 422 | `error_variant_unavailable` | Товар больше не продаётся | `removeLine` |
| `QTY_NOT_MULTIPLE` | 422 | `error_qty_not_multiple` | Количество должно быть кратно {m} {unit} | `adjustQuantity` |
| `QTY_BELOW_MIN` | 422 | `error_qty_below_min` | Минимальная партия — {min} {unit} | `adjustQuantity` |
| `DISCOUNT_LIMIT_EXCEEDED` | 422 | `error_discount_limit_exceeded` | Скидка больше вашего лимита ({limit} %) | `seniorApproval` |
| `CREDIT_BLOCKED` | 422 | `error_credit_blocked` | Продажа в долг недоступна | `changePaymentMethod` |
| `CREDIT_LIMIT_EXCEEDED` | 422 | `error_credit_limit_exceeded` | Превышен лимит долга клиента | `changePaymentMethod` |
| `RECEIVABLES_STALE` | 422 | `error_receivables_stale` | Данные о долге устарели | `changePaymentMethod` |
| `ONEC_UNAVAILABLE` | 503 | `error_onec_unavailable` | 1С временно недоступна. Заказ будет отправлен позже | `onecPending` |
| `ONEC_REJECTED` | 422 | `error_onec_rejected` | 1С отклонила документ | `refreshCart` |
| `ORDER_STATE_INVALID` | 409 | `error_order_state_invalid` | Действие недоступно в текущем статусе | `reloadEntity` |
| `PAYMENT_STATE_INVALID` | 409 | `error_payment_state_invalid` | Статус платежа изменился | `reloadEntity` |
| `CUSTOMER_LINK_CONFLICT` | 409 | `home_link_conflict` | Привязка к организации ожидает подтверждения администратором | `none` |
| `CUSTOMER_DUPLICATE_SUSPECTED` | 409 | `error_customer_duplicate_suspected` | Найден клиент с этим номером | `chooseExistingCustomer` |
| `SYNC_ALREADY_RUNNING` | 409 | `error_sync_already_running` | Синхронизация уже выполняется | `none` |
| `NOT_FOUND` | 404 | `error_not_found` | Не найдено | `none` |
| `RATE_LIMITED` | 429 | `error_rate_limited` | Слишком много запросов, подождите {seconds} с | `retryAfter` |
| `INTERNAL` | 500 | `error_internal` | Не удалось выполнить. Повторите | `contactSupport` |
| `APP_UPDATE_REQUIRED` | 426 | `ds_update_required` | Требуется обновление приложения | `updateApp` |
| `PAYLOAD_TOO_LARGE` | 413 | `error_internal` | Не удалось выполнить. Повторите | `reportClientError` |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | `error_internal` | Не удалось выполнить. Повторите | `reportClientError` |
| `METHOD_NOT_ALLOWED` | 405 | `error_internal` | Не удалось выполнить. Повторите | `reportClientError` |
| `CUSTOMER_NOT_IDENTIFIED` | 422 | `error_customer_not_identified` | Выберите клиента | `chooseCustomer` |
| `CART_EMPTY` | 422 | `error_cart_empty` | Корзина пуста | `refreshCart` |
| `PIN_INVALID` | 401 | `auth_pin_error_invalid` | Неверный PIN. Осталось попыток: {n} | `none` |
| `PIN_LOCKED` | 423 | `auth_pin_locked` | PIN заблокирован после 5 неверных попыток. Войдите по SMS и задайте новый PIN | `signIn` |
| `UNLOCK_REQUIRED` | 401 | `unlock_locked_title` | Экран заблокирован | `unlock` |
| `RETURN_QTY_EXCEEDED` | 422 | `error_return_qty_exceeded` | Можно вернуть не больше {n} | `adjustQuantity` |
| `WEBHOOK_SIGNATURE_INVALID` | 401 | `error_internal` | Не удалось выполнить. Повторите | `reportClientError` |
| `QR_UNAVAILABLE` | 503 | `error_qr_unavailable` | QR временно недоступен | `qrManualFallback` |
| `CONSENT_REQUIRED` | 422 | `reg_error_consent_required` | Чтобы продолжить, подтвердите, что ознакомлены с условиями обработки данных | `provideConsent` |
| `APP_READ_ONLY` | 503 | `error_app_read_only` | Сервер работает в режиме только чтения — изменения временно недоступны | `readOnlyMode` |

## Предупреждения успешного ответа (`warnings[].code`)

| Код | HTTP | Ключ ARB | Текст (ru) | Действие |
|---|---|---|---|---|
| `STALE_DATA` | 2xx | `ds_onec_down` | 1С недоступна: заказы будут отправлены позже; продажа в долг — только по актуальным данным о долге | `onecPending` |
| `QR_UNAVAILABLE` | 2xx | `order_created_qr_unavailable_onec` | QR не получен из 1С. Покажите QR-табличку кассы — оплату подтвердит кассир — или выберите другой способ | `qrManualFallback` |
| `PAYMENT_AMOUNT_MISMATCH` | 2xx | `payment_review_amount_mismatch` | Требует проверки: сумма не совпадает | `reloadEntity` |
