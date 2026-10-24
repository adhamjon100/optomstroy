# Этап C — пробные сборки (RM-C-013)

Дата: 2026-10-21. Машина: Windows 11 Pro 10.0.26200 (25H2), интерактивный сеанс пользователя.
Журнал команд и фактических выводов — `docs/stages/C_checks.log` (разделы «RM-C-013»). CI не запускался: хранилища
кода и раннеров нет (Q-131), поэтому критерий 1 RM-C-013 («обе команды — код 0 в CI») локальной сборкой закрывается
только частично.

## 1. Версии инструментов (`flutter --version`, `flutter doctor -v`)

| Компонент | Версия |
|---|---|
| Flutter / Dart | 3.38.7 (stable, framework 3b62efc2a3, engine 78fc3012e4) / Dart 3.10.7 |
| Visual Studio | Community 2022 17.14.21 (17.14.36717.8), workload C++; Windows 10 SDK 10.0.26100.0 |
| CMake | из VS 2022 (`flutter build windows` собрал без отдельной установки) |
| Android SDK | 36.0.0, build-tools 36.0.0, emulator 35.4.9; **лицензии не приняты** (`! Some Android licenses not accepted`) |
| JDK | Android Studio JBR 21.0.6 (для Gradle); в PATH первым стоит Java 8 (1.8.0_251), установлен также JDK 17.0.12 |

Замечание окружения: `flutter doctor` показывает `ANDROID_HOME = C:\Program Files\Java\jdk-17` — переменная указывает на
JDK, а не на Android SDK. Перед сборкой apk её нужно исправить на `C:\Users\<user>\AppData\Local\Android\Sdk`
(или удалить) — действие заказчика вместе с принятием лицензий.

## 2. Windows release — выполнено

| Команда | Код | Время | Результат |
|---|---|---|---|
| `flutter build windows --release` | 0 | 173 с (первая, чистая сборка); 33 с (повтор в финальном прогоне) | `build\windows\x64\runner\Release\optomstroy.exe` |
| `flutter build windows --release --dart-define-from-file=env/dev.json` | 0 | 12–37 с (инкрементально) | то же с профилем dev (RM-C-009 п. 6) — итоговый артефакт |

Риск этапа C «сборка Windows требует ATL для flutter_secure_storage» на этой машине **не сработал**:
`flutter_secure_storage_windows_plugin.dll` собран без дополнительных компонентов VS.

### 2.1. Состав и размер артефакта

Каталог `Release\` — 25 файлов, **34 904 833 байт (≈ 33,3 МБ)**; zip-архив каталога — **15 102 487 байт (≈ 14,4 МБ)**.

| Файл | Байт | Откуда |
|---|---|---|
| `flutter_windows.dll` | 18 512 384 | движок Flutter |
| `data/app.so` | 6 046 640 | AOT-код приложения |
| `rive_native.dll` + `rive_native_plugin.dll` | 4 078 080 + 281 088 | rive 0.14 |
| `sqlite3.dll` | 1 478 656 | sqlite3_flutter_libs 0.5.42 (**FTS5 включён**: строка `ENABLE_FTS5` в опциях компиляции) |
| `data/icudtl.dat` | 778 864 | ICU |
| `local_auth_windows_plugin.dll` | 178 176 | Windows Hello (D-13: UX-гейт + PIN) |
| `flutter_secure_storage_windows_plugin.dll` | 159 744 | secure storage |
| `connectivity_plus_plugin.dll`, `dartjni.dll`, `sqlite3_flutter_libs_plugin.dll`, `optomstroy.exe` | 102 400, 59 904, 9 728, 92 672 | плагины, раннер |
| `data/flutter_assets/assets/fonts/Inter/*.ttf` | 4 × ≈ 330 000 | Inter 400/500/600/700 из pubspec (`FontManifest.json` содержит семейство Inter), `OFL.txt` |

SHA-256 (сборка с `env/dev.json`): `optomstroy.exe` (раннер) `afbad8c8a6b8849b50911a1b3559979401a3fe5246b57bc6eb3ec9401c084656`, `data/app.so` `980cdb0d53afaf9d81d8bd2e438f359c8fc3a4813298712befc487956736fd59`.
В release нет служебного маршрута `/dev/gallery`: он подключается в `app_router.dart` под `if (kDebugMode)`, поэтому код витрины
выбрасывается из AOT (проверено размером: с условием на месте вызова каталог Release — 34 904 833 байт, `app.so` — 6 046 640; без него
каталог был 35 134 209 байт, т. е. +229 376 байт кода витрины).

Для поставки на POS без Visual Studio нужен VC++ Redistributable (`msvcp140.dll`, `vcruntime140.dll`,
`vcruntime140_1.dll`; R3 §13) — в каталог Release он не входит. Формат дистрибуции (zip или MSIX) — R2 (06 §6.16).

### 2.2. Запуск на Windows

`optomstroy.exe` (Release, профиль dev) запущен в интерактивном сеансе: процесс живёт, окно `optomstroy` открыто,
рабочий набор ≈ 152 МБ, DPI окна 120 (масштаб 125 %). Снимок клиентской области через `PrintWindow`:
`docs/stages/C_assets/windows_release_boot.png` — экран-заглушка «нет сессии» SCR-01 («Вход по номеру телефона»)
со шрифтом Inter; строки «Сервер недоступен» нет, т. е. `GET /health` к локальному pos-api прошёл.

Ограничения по критерию 2 («скриншот Splash с версией»):
- Splash (SCR-00) виден один кадр: заглушка `sessionStatusProvider` сразу отвечает «нет сессии» (реальное
  восстановление сессии — RM-D). Показ Splash подтверждён integration-тестом `integration_test/boot_test.dart`
  (тест держит восстановление сессии и проверяет Splash, затем переход) — см. `C_checks.log`.
- Версии на Splash пока нет: логотип и версия — RM-D-007 / SCR-00 (03 §14, O-22). Версия приложения `0.1.0+1`
  уходит в `X-App-Version` (ClientMeta, RM-C-015).
- Заголовок окна — `optomstroy` (имя из шаблона `windows/runner/main.cpp`); локализованное название и иконка —
  вместе с брендингом RM-D-007.
- Отдельного Windows-POS заказчика (O-13) нет: запуск выполнен на машине разработки.

## 3. Android debug — НЕ выполнялось

`flutter build apk --debug` не запускался по условию этапа: лицензии Android SDK не приняты, их принимает заказчик
(`flutter doctor --android-licenses`). Физического Android-устройства нет (O-13, RM-A-008). Что нужно для сборки:

1. принять лицензии SDK; исправить `ANDROID_HOME` (§1);
2. `cd pos-app && flutter build apk --debug --dart-define-from-file=env/dev.json`;
3. до RM-D-008 (биометрия): `MainActivity` → `FlutterFragmentActivity`, разрешение `USE_BIOMETRIC`,
   `android:allowBackup="false"` (R3 §6.1, §13) — сейчас в шаблоне `FlutterActivity` и разрешений нет;
   `applicationId` по-прежнему `com.example.optomstroy` (pos-app/NOTES.md §7).

## 4. iOS — только требования (Q-008, R3 §13; сборка невозможна — нет macOS)

Недостающее для сборки и запуска iOS:

| # | Что нужно | Состояние в репозитории |
|---|---|---|
| 1 | Mac с macOS и Xcode, совместимым с Flutter 3.38 (или macOS-раннер CI: GitHub Actions macOS / Codemagic) | нет; Q-008 |
| 2 | Apple Developer Program (подпись, provisioning profile, TestFlight) | нет |
| 3 | `IPHONEOS_DEPLOYMENT_TARGET` поднять с 13.0 до ≥ 15.0 (минимум Flutter), до 15.5 при ML Kit (SCR-05, R2) | `ios/Runner.xcodeproj`: 13.0 |
| 4 | `Info.plist`: `NSFaceIDUsageDescription` (local_auth), `NSCameraUsageDescription` (mobile_scanner) | ключей нет |
| 5 | Entitlement `keychain-access-groups` (flutter_secure_storage / биометрический Keychain) | нет |
| 6 | Bundle identifier заказчика вместо `com.example.optomstroy` | шаблонный |
| 7 | `pod install` (CocoaPods) для плагинов: local_auth_darwin, flutter_secure_storage, sqlite3_flutter_libs, mobile_scanner, rive_native, connectivity_plus, package_info_plus, device_info_plus | не выполнялся |
| 8 | Проверка чек-листа криптопривязки (б) на устройстве: `kSecAccessControlBiometryCurrentSet` + `WhenPasscodeSetThisDeviceOnly` | `docs/stages/C_biometric_prototype.md` |

## 5. Итог по критериям RM-C-013

| Критерий | Статус |
|---|---|
| 1. `flutter build windows --release` и `flutter build apk --debug` — код 0 в CI | Windows — код 0 локально; apk — не выполнялся (лицензии); CI — не запускался (Q-131) |
| 2. Запуск на Windows- и Android-устройстве, скриншот Splash с версией | Windows: запуск на машине разработки, скриншот экрана «нет сессии»; Splash — один кадр (см. §2.2), версии на Splash нет (RM-D-007); Android — нет устройства |
| 3. Список недостающего для iOS | §4 |
| 4. Протокол чек-листа `biometric_storage` (а)–(г) | `C_biometric_prototype.md`: статус «ожидает устройства»; найдена несовместимость пакета с текущим набором зависимостей |
| 5. ADR о пути криптопривязки до старта RM-D-008 | не принят: нет протокола на устройстве (см. `C_biometric_prototype.md` §5) |
