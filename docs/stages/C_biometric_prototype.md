# Этап C — прототип криптопривязки биометрии (RM-C-013, D-13, ядро R0 §21 п. 2)

Дата: 2026-10-21. **Статус: ОЖИДАЕТ УСТРОЙСТВА** (и решения по версии Flutter, см. §2).
Протокол на устройстве не составлен, ADR о выбранном пути (уточнение ADR-013) не принят.
**Обновление 2026-10-22 (RM-D-008):** путь выбран — собственный platform channel (ADR-087); протокол на устройстве по-прежнему ожидает устройства — §6.

## 1. Почему прототип не выполнен

| Препятствие | Подробности | Чьё действие |
|---|---|---|
| Нет Android-устройства | для пунктов (а), (в), (г) нужен телефон с датчиком класса 3 (`BIOMETRIC_STRONG`) и возможностью добавить новый отпечаток/лицо; эмулятор допустим только как «ручной протокол с пометкой» (13, риски этапа D) | заказчик: O-13 / RM-A-008 |
| Не приняты лицензии Android SDK | `flutter doctor`: `Some Android licenses not accepted`; apk не собирается. Кроме того, `ANDROID_HOME` указывает на JDK (`docs/stages/C_builds.md` §1) | заказчик |
| Нет macOS | iOS-пункт (б) по ядру проверяется «по документации пакета и коду, без устройства» (R3 §13) | — |
| **Пакет не ставится в текущий набор зависимостей** | см. §2 — фактический прогон `flutter pub add … --dry-run` | ARCH/FE + заказчик (версия Flutter) |

## 2. Совместимость `biometric_storage` с каркасом (проверено командами, журнал `C_checks.log`)

| Команда (`pos-app/`, без изменения pubspec) | Код | Вывод pub |
|---|---|---|
| `flutter pub add biometric_storage:^5.0.1 --dry-run` | 65 | `biometric_storage >=5.0.0 <6.0.0-dev.2 depends on win32 >=2.0.0 <6.0.0` и `device_info_plus >=13.1.0 depends on win32 ^6.0.1` — несовместимы |
| то же + `device_info_plus:>=12.0.0 <13.1.0` | 65 | следующий конфликт: `package_info_plus >=10.1.0` (win32 ^6.0.1) |
| то же + `package_info_plus:>=8.0.0 <10.1.0` | 65 | `flutter_secure_storage >=11.0.0-beta.1` → `flutter_secure_storage_windows ^4.2.2` (win32 ^6.0.1) — **несовместим с flutter_secure_storage 11** (R3 §15, D-13) |
| `flutter pub add 'biometric_storage:>=6.0.0-dev.2 <7.0.0' --dry-run` | 65 | `biometric_storage >=6.0.0-dev.2 requires Flutter SDK version >=3.44.0` (у нас 3.38.7) |

Вывод: на Flutter 3.38.7 `biometric_storage` нельзя подключить рядом с `flutter_secure_storage` 11.
Ветка 5.x требует win32 < 6 (это откат secure storage до 10.x и `package_info_plus`/`device_info_plus` на
старые мажорные версии); ветка 6.0.0-dev — Flutter ≥ 3.44 и пока pre-release. Это совпадает с рекомендацией
`pos-app/NOTES.md` §1 обновить Flutter (там — до Dart ≥ 3.13 для набора R3 §15).

Варианты для решения ARCH/SEC до старта RM-D-008:
1. **Обновить Flutter до ≥ 3.44** и проверить `biometric_storage` 6.x по чек-листу (пакет pre-release — отдельный
   риск поддержки, R3 §6.2: «2 года без стабильного релиза»).
2. **Собственный platform channel** (Kotlin/Swift) — ядро допускает его, если пакет «не поддерживается»;
   несовместимость с обязательным `flutter_secure_storage` 11 на текущем SDK — формальное основание, но ядро требует
   сначала прототип, поэтому рекомендуется сначала вариант 1 на устройстве.
3. Откат `flutter_secure_storage` до 10.x — **не рекомендуется** (R3 §5, D-13 закрепляют 11.x).

## 3. План прототипа (выполнить при наличии устройства)

Отдельная ветка/каталог `pos-app/tool/biometric_prototype/` (в основной `lib/` прототип не входит), Android API ≥ 28.

| Пункт чек-листа (ядро §21 п. 2) | Как проверить | Ожидаемый результат | Итог |
|---|---|---|---|
| (а) Android: Keystore-ключ, `setUserAuthenticationRequired(true)`, проверка на каждое использование через `BiometricPrompt.CryptoObject` (без окна валидности), инвалидация при добавлении отпечатка/лица | `BiometricStorage().getStorage('biometric_refresh', options: StorageFileInitOptions(...))` с валидностью «на каждое использование» и только биометрией (точные имена параметров — по выбранной версии пакета); запись/чтение 3 раза подряд — промпт каждый раз; затем добавить отпечаток в настройках ОС и прочитать; `adb shell dumpsys keystore2` / логи `KeyPermanentlyInvalidatedException` | промпт на каждое чтение; после нового отпечатка — исключение инвалидации | ожидает устройства |
| (б) iOS: Keychain `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | чтение исходников пакета (`ios/Classes/*.swift`: флаги `SecAccessControlCreateWithFlags`) и документации; устройства нет (R3 §13) | оба флага выставляются для `authenticationRequired` | ожидает анализа кода версии, выбранной по §2 |
| (в) Инвалидация → удаление `biometric_refresh`, `sessions.revoke_reason=biometric_invalidated` | после (а): обработчик исключения удаляет запись и вызывает `POST /auth/sessions/...` (RM-D-003); проверка строки `sessions` в БД тестового контура | запись удалена, сессия отозвана с нужной причиной | ожидает устройства и RM-D-003 |
| (г) Только сильная биометрия: Android `BIOMETRIC_STRONG`, iOS `BiometryCurrentSet` (без кода устройства); без биометрии — PIN приложения (D-48) | Android: устройство с лицом класса 2 — ключ недоступен; отключить биометрию — переход на PIN; iOS — по коду (б) | слабая биометрия и код устройства не открывают ключ | ожидает устройства |

Протокол по каждому пункту: модель устройства, версия Android/iOS, версия пакета, шаги, скриншоты/логи, «пройден / не
пройден». Вывод: «`biometric_storage` / собственный platform channel» с обоснованием → ADR в 15_DECISION_LOG
(уточнение ADR-013), до старта RM-D-008. Windows не меняется: Windows Hello — UX-гейт + PIN (D-13, D-48);
`local_auth_windows_plugin.dll` уже в Windows-сборке (`C_builds.md` §2.1).

## 4. Требования iOS (R3 §13), относящиеся к биометрии

- `NSFaceIDUsageDescription` в `ios/Runner/Info.plist` — сейчас нет;
- `IPHONEOS_DEPLOYMENT_TARGET` ≥ 15.0 (сейчас 13.0);
- entitlement `keychain-access-groups`;
- проверка флагов Keychain (пункт б) — по коду выбранной версии пакета;
- Mac + Xcode + Apple Developer Program для подписи и запуска на устройстве (Q-008).
Полный список недостающего для iOS — `docs/stages/C_builds.md` §4.

## 5. Что нужно, чтобы закрыть RM-C-013 п. 4–5

1. Заказчик: Android-устройство с биометрией класса 3 (O-13), принятие лицензий SDK, исправление `ANDROID_HOME`.
2. ARCH/FE: решение по версии Flutter (≥ 3.44 для `biometric_storage` 6.x) — либо обоснованный переход к
   platform channel (ADR).
3. FE + SEC: прогон плана §3, протокол в этом файле, ADR в 15_DECISION_LOG.

## 6. Статус на этапе D (RM-D-008, 2026-10-22)

**Итог: путь выбран — собственный platform channel** (ADR-087 в `docs/specification/15_DECISION_LOG.md`, приложение Г;
уточнение ADR-013/ADR-077). Основание — §2: `biometric_storage` на Flutter 3.38.7 не ставится рядом с
`flutter_secure_storage` 11 (ядро §21 п.2: «пакет не поддерживается»). Прототип пакета (план §3, `tool/biometric_prototype/`)
не делается — чек-лист (а)–(г) переносится на собственный канал. **Протокол на устройстве по-прежнему ожидает устройства.**

| Что | Где | Состояние |
|---|---|---|
| Dart-порт `BiometricAuthenticator` + `BiometricCryptoChannel` (канал `kg.optomstroy/biometric_crypto`), `WindowsHelloGate`, провайдер | `pos-app/lib/core/biometrics/` | готово; юнит-тесты протокола на моке канала (`test/features/registration/biometrics/biometric_port_test.dart`) |
| Android: Keystore AES-256-GCM, `setUserAuthenticationRequired(true)`, `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`, `setInvalidatedByBiometricEnrollment(true)`, StrongBox с откатом; `BiometricPrompt` (framework, API 30) + `CryptoObject`; API < 30 — не предлагается | `android/app/src/main/kotlin/com/example/optomstroy/BiometricCryptoChannel.kt`, `MainActivity` → `FlutterFragmentActivity`, `AndroidManifest.xml`: `USE_BIOMETRIC`, `allowBackup="false"` | **компилируется**: `gradlew.bat :app:compileDebugKotlin` → `BUILD SUCCESSFUL`, код 0 (JBR 21, `ANDROID_HOME` = SDK, без принятия лицензий); apk не собирался (лицензии) |
| iOS: Keychain `.biometryCurrentSet` + `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`; `NSFaceIDUsageDescription` | `ios/Runner/AppDelegate.swift` (класс `BiometricCrypto`), `ios/Runner/Info.plist` | написано; **не компилировалось** (нет macOS, Q-008) |
| Windows Hello — UX-гейт без секретов | `WindowsHelloGate` (`local_auth`) | готово; `flutter build windows --release` — код 0 |
| Использование в регистрации (SCR-04): `POST /me/biometrics` → `store()`; отказ → удаление ключа и отзыв семьи | `pos-app/lib/features/registration/` | готово; widget-тесты SCR-04 с моком порта |

Чек-лист ядра §21 п.2 на устройстве (план §3, теперь — для канала, а не пакета):

| Пункт | Как проверить на канале | Итог |
|---|---|---|
| (а) Android: промпт на каждое использование, инвалидация новым отпечатком/лицом | регистрация с включённой биометрией → 3 разблокировки SCR-08 подряд (промпт каждый раз) → добавить отпечаток в настройках ОС → разблокировка: ожидается `invalidated` (в `adb logcat` — `KeyPermanentlyInvalidatedException` не логируется приложением, проверяется по поведению: ключ удалён, предложены PIN/SCR-01) | ожидает устройства |
| (б) iOS: `kSecAccessControlBiometryCurrentSet` + `WhenPasscodeSetThisDeviceOnly` | Xcode: атрибуты элемента `kg.optomstroy.biometric_refresh`; смена набора Face ID → `invalidated` | ожидает macOS/устройства (код — `AppDelegate.swift`) |
| (в) инвалидация → удаление `biometric_refresh`, `sessions.revoke_reason=biometric_invalidated` | после (а): `POST /auth/unlock {method: pin, biometricInvalidated: true}` (RM-D-009); строка `sessions` тестового контура | ожидает устройства; клиентская часть — юнит-тест протокола |
| (г) только сильная биометрия | устройство с лицом Class 2: `capability` = `unsupported` (`canAuthenticate(BIOMETRIC_STRONG)`), вход по PIN | ожидает устройства |

Нужно для закрытия: Android-устройство Class 3 (O-13), принятие лицензий SDK и исправление `ANDROID_HOME` (заказчик);
macOS + Xcode для iOS (Q-008). Протокол (модель, версия ОС, шаги, логи, «пройден / не пройден») — дописать сюда.
