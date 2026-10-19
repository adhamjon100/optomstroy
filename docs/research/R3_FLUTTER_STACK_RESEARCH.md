# R3 — Исследование технологического стека Flutter-приложения «Оптомстрой» (Release 1)

**Агент:** 3 — Flutter-архитектор
**Дата обращения к источникам:** 2026-10-18
**Статус документа:** исходник для ТЗ (разделы 06_ARCHITECTURE, 13_IMPLEMENTATION_ROADMAP, 12_TEST_PLAN, 15_DECISION_LOG)
**Режим:** ЭТАП 1 (исследование). Код не писался, проект не изменялся.

Легенда статусов утверждений:
- `[ПОДТВЕРЖДЕНО: <источник>]` — проверено по официальной странице/команде.
- `[ТИПОВО: <контекст>, требует проверки]` — верно для типовых конфигураций, нужна проверка у заказчика / на сборке.
- `[НЕ ПОДТВЕРЖДЕНО]` — предположение автора.

Примечание о датах релизов: страница пакета на pub.dev показывает относительную дату («published N days ago»). Для пакетов со статусом **ВКЛЮЧИТЬ** (и для опциональных lottie/camera/ML Kit) в колонке «Дата» проставлена точная календарная дата последнего релиза (UTC) из поля `published` JSON-ответа `https://pub.dev/api/packages/<имя>` (это те же данные, что на вкладке Versions) `[ПОДТВЕРЖДЕНО: pub.dev API, 2026-10-18]`. Для отклонённых/отложенных пакетов оставлена относительная дата со страницы pub.dev (точная дата для ТЗ не требуется).

---

## 0. Локальное окружение (подтверждено командами)

`[ПОДТВЕРЖДЕНО: flutter --version; flutter doctor -v, выполнено 2026-10-18]`

| Компонент | Значение |
|---|---|
| Flutter | 3.38.7, channel stable, revision 3b62efc2a3 (2026-01-13), engine 78fc3012e4 |
| Dart | 3.10.7, DevTools 2.51.1 |
| ОС | Windows 11 Pro 10.0.26200 (25H2), locale ru-UA |
| Feature flags | enable-windows-desktop, enable-android, enable-ios, enable-web, enable-native-assets и др. — включены |
| Android toolchain | Android SDK 36.0.0, build-tools 36.0.0, platform android-36, эмулятор 35.4.9; JDK 21 (JBR Android Studio). **Предупреждение:** `Some Android licenses not accepted` → перед первой сборкой выполнить `flutter doctor --android-licenses` |
| Visual Studio | Community 2022 17.14.21 (17.14.36717.8), Windows 10 SDK 10.0.26100.0 — `flutter doctor` отмечает `[√]`, т.е. workload «Desktop development with C++» установлен |
| Chrome / Edge | Chrome 155, Edge 152 (web-таргет доступен) |
| Устройства | Windows (desktop) windows-x64, Chrome, Edge. Физических Android/iOS-устройств не подключено |
| macOS / Xcode | **Отсутствуют** (Windows-хост) → iOS-сборка на этой машине невозможна |

Шаблон проекта (`flutter create`, не изменялся) `[ПОДТВЕРЖДЕНО: чтение D:\optomstroy\android\app\build.gradle.kts, settings.gradle.kts, ios/Runner.xcodeproj/project.pbxproj, windows/CMakeLists.txt]`:
- Android: `minSdk = flutter.minSdkVersion`, `compileSdk = flutter.compileSdkVersion`, Java 17, AGP 8.11.1, Kotlin 2.2.20, Gradle 8.14, applicationId `com.example.optomstroy` (заменить на реальный).
- Значения по умолчанию из SDK (`C:\dev\flutter\packages\flutter_tools\gradle\src\main\kotlin\FlutterExtension.kt`): **minSdkVersion = 24, compileSdkVersion = 36, targetSdkVersion = 36, ndkVersion = 28.2.13676358** `[ПОДТВЕРЖДЕНО: grep по локальному Flutter SDK]`.
- iOS: `IPHONEOS_DEPLOYMENT_TARGET = 13.0` в шаблоне, но Flutter 3.38 поддерживает iOS 15+ (см. §13) и ML Kit требует 15.5 → при разработке поднять до 15.5.
- Windows: CMake ≥ 3.14, проект `optomstroy`, язык CXX.
- `lib/` содержит только `main.dart` шаблона; `test/` — `widget_test.dart` шаблона. Реального кода нет.

Поддерживаемые Flutter-платформы `[ПОДТВЕРЖДЕНО: https://docs.flutter.dev/reference/supported-platforms]`: Android API 24–37 (минимум 24, x64/Arm32/Arm64); iOS 15–27 (минимум 15, Arm64); Windows 10 и 11 (x64, Arm64). API 23 и ниже, iOS 14 и ниже, Windows 8 и ниже — не поддерживаются.

---

## 1. Сводная таблица пакетов-кандидатов

Столбцы: имя | версия на pub.dev | дата последнего релиза (точная, UTC — для включённых пакетов; относительная на 2026-10-18 — для остальных) | лицензия | платформы | статус (издатель / Flutter Favorite) | решение и причина.
Все строки `[ПОДТВЕРЖДЕНО: https://pub.dev/packages/<имя>, 2026-10-18]`, если не указано иное. FF = Flutter Favorite.

### 1.1. Состояние и DI

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| flutter_riverpod | 3.4.3 | 2026-09-03 | MIT | Android, iOS, Linux, macOS, Windows (Web в списке pub.dev не выведен; riverpod — pure Dart) | dash-overflow.net (verified), **FF** | **ВКЛЮЧИТЬ** — состояние + DI в одном, тестируемость через `ProviderContainer.test` |
| riverpod_annotation | 4.0.7 | 2026-09-03 | MIT | все | dash-overflow.net (verified) | **ВКЛЮЧИТЬ** (кодогенерация провайдеров) |
| riverpod_generator | 4.0.9 | 2026-09-03 | MIT | — (dev) | dash-overflow.net (verified) | **ВКЛЮЧИТЬ** (dev_dependency) |
| riverpod_lint | 3.1.9 | 2026-09-03 | MIT | — (dev) | pub.dev показывает «unverified uploader» | **ВКЛЮЧИТЬ** (линты) — неверифицированный аплоадер на pub.dev, но пакет из той же монорепы Riverpod `[ТИПОВО, требует проверки]`. **Важно:** с версии 3.x riverpod_lint реализован на `analysis_server_plugin` и подключается через `analysis_options.yaml` (`plugins: riverpod_lint: <version>`), а **не** через `custom_lint`; README: «Riverpod_lint is implemented using analysis_server_plugin. As such, it is installed through analysis_options.yaml»; pubspec 3.1.9 не зависит от custom_lint/custom_lint_builder `[ПОДТВЕРЖДЕНО: https://pub.dev/packages/riverpod_lint; https://pub.dev/api/packages/riverpod_lint]` |
| hooks_riverpod + flutter_hooks | 3.4.3 / 0.21.3+1 | 44 дн. / 14 мес. | MIT | все | dash-overflow.net (verified), FF | **ОТКЛОНИТЬ** — хуки не нужны для Clean Architecture; уменьшаем поверхность API и порог входа |
| flutter_bloc | 9.1.1 | 17 мес. (≈2025-05) | MIT | все | bloclibrary.dev (verified), **FF** | **ОТКЛОНИТЬ** (альтернатива) — не даёт DI, больше шаблонного кода (events/states), последний релиз 17 мес. назад |
| signals / signals_flutter | 7.1.0 | 4 мес. | Apache-2.0 | все | rodydavis.com (verified), не FF | **ОТКЛОНИТЬ** — меньшая экосистема, нет DI, нет официальной методики тестирования уровня Riverpod |
| get_it | 9.3.0 | 28 дн. | MIT | все | flutter-it.dev (verified) | **ОТКЛОНИТЬ** — DI уже покрыт Riverpod; второй контейнер = дублирование |

### 1.2. Навигация

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| go_router | 18.1.0 | 2026-10-14 | BSD-3-Clause | все | flutter.dev (verified), **FF** | **ВКЛЮЧИТЬ** |
| go_router_builder | 4.5.0 | 2026-09-02 | BSD-3-Clause | все | flutter.dev (verified) | **ВКЛЮЧИТЬ** (типизированные маршруты) |
| auto_route | 11.2.0 | 26 дн. | MIT | все | codeness.ly (verified) | **ОТКЛОНИТЬ** — зрелый, но сопровождается одним издателем; go_router поддерживается командой Flutter |

### 1.3. Локальное хранилище

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| drift | 2.35.2 | 2026-10-07 | MIT | Android, iOS, Linux, macOS, Web, Windows | simonbinder.eu (verified), **FF** | **ВКЛЮЧИТЬ** — SQL, миграции, типизированные запросы, фоновый изолят, Windows без доп. настройки |
| drift_dev, build_runner | 2.35.1 / 2.17.1 | 2026-09-30 / 2026-10-14 | MIT / BSD-3 | dev | simonbinder.eu (verified) / tools.dart.dev (verified) | **ВКЛЮЧИТЬ** (dev) — drift_dev 2.35.1 допускает `drift >=2.30.0 <2.36.0`, т.е. совместим с drift 2.35.2 `[ПОДТВЕРЖДЕНО: https://pub.dev/api/packages/drift_dev, pubspec 2.35.1]` |
| drift_flutter | 0.3.1 | 2026-07-11 | MIT | все | simonbinder.eu (verified) | **ВКЛЮЧИТЬ** — хелпер `driftDatabase(name:)`, путь к файлу, `shareAcrossIsolates` |
| sqlite3 | 3.7.1 | 2026-10-13 | MIT | все | simonbinder.eu (verified) | **ВКЛЮЧИТЬ** (транзитивно) — с 3.0.0 сам бандлит нативный SQLite через hooks/native assets |
| sqlite3_flutter_libs | 0.6.0+eol | 8 мес. | MIT | все | simonbinder.eu, **obsolete / EOL** (версия `0.6.0+eol`; pub.dev не помечает пакет как discontinued) | **ОТКЛОНИТЬ** — уведомление в метаданных pub.dev: «Not used anymore, update to version 3.x of package:sqlite3 instead»; Caution-блок README: «This package relates to version 2.x of `package:sqlite3`, and is obsolete after upgrading» и «Starting from version `0.6.0`, this package no longer does anything» `[ПОДТВЕРЖДЕНО: https://pub.dev/packages/sqlite3_flutter_libs]` |
| isar | 3.1.0+1 (prerelease 4.0.0-dev.14) | **3 года** | Apache-2.0 | все | isar.dev (verified) | **ОТКЛОНИТЬ** — стабильная ветка 3 года без релизов; README GitHub: «ISAR V4 IS NOT READY FOR PRODUCTION USE»; 173 открытых issue `[ПОДТВЕРЖДЕНО: https://github.com/isar/isar]` |
| isar_community | 3.4.1 | 4 дн. | Apache-2.0 | Android, iOS, Linux, macOS, Windows | isar-community.dev (verified) | **ОТКЛОНИТЬ** — активный форк «bug fixes and small updates for version 3», но зависит от нативного бинарного ядра; NoSQL без SQL/FTS; риск долгосрочной поддержки |
| hive | 2.2.3 (prerelease 4.0.0-dev.2) | **4 года** | «unknown» в метаданных pub.dev (README: Apache-2.0) | все | isar.dev (verified) | **ОТКЛОНИТЬ** — фактически не сопровождается |
| hive_ce | 2.22.0 | 3 дн. | Apache-2.0, BSD-3-Clause | все | iodesignteam.com (verified) | **ОТКЛОНИТЬ для R1** — активный key-value, `IsolatedHive`, но нет запросов/индексов; для каталога на десятки тысяч товаров не подходит; для настроек достаточно shared_preferences |
| sqflite | 2.4.4+2 | 4 дн. | BSD-2-Clause | **Android, iOS, macOS** | tekartik.com (verified), FF | **ОТКЛОНИТЬ** — нет Windows (нужен отдельный sqflite_common_ffi), нет типизации/миграций уровня drift |
| objectbox | 5.3.2 (prerelease 6.0.0-preview.4) | 5 мес. | Apache-2.0 (Dart-биндинги) | Android, iOS, Linux, macOS, Windows | objectbox.io (verified) | **ОТКЛОНИТЬ** — нативное ядро с закрытым исходным кодом `[НЕ ПОДТВЕРЖДЕНО]`, нет SQL/FTS, меньшая прозрачность |
| shared_preferences | 2.5.6 | 2026-10-05 | BSD-3-Clause | все | flutter.dev (verified), **FF** | **ВКЛЮЧИТЬ** — несекретные настройки (тема, последний вид каталога, «запомнить меня» = только флаг) |
| path_provider | 2.1.6 | 2026-06-15 | BSD-3-Clause | Android, iOS, Linux, macOS, Windows | flutter.dev (verified) | **ВКЛЮЧИТЬ** (транзитивно через drift_flutter / cache manager) |

### 1.4. Безопасное хранение и биометрия

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| flutter_secure_storage | 11.2.0 | 2026-09-16 | BSD-3-Clause | Android, iOS, Linux, macOS, Web, Windows | steenbakker.dev (verified) | **ВКЛЮЧИТЬ** — токены сессии, refresh-токен, device-id |
| local_auth | 3.0.2 | 2026-07-09 | BSD-3-Clause | Android 24+, iOS 13+, macOS 10.15+, Windows 10+ | flutter.dev (verified) | **ВКЛЮЧИТЬ** — системная биометрия как «второй фактор удобства» |
| local_auth_android | 2.3.0 | 4 дн. | BSD-3-Clause | Android | flutter.dev (verified), endorsed | транзитивно |
| local_auth_darwin | 2.0.5 | 36 ч. | BSD-3-Clause | iOS, macOS | flutter.dev (verified), endorsed | транзитивно |
| local_auth_windows | 2.0.2 | 51 дн. | BSD-3-Clause | Windows | flutter.dev (verified), endorsed | транзитивно |
| biometric_storage | 5.0.1 (prerelease 6.0.0-dev.5) | **2 года** | MIT | Android, iOS, macOS, Linux, Windows, Web | codeux.design (verified) | **ОТЛОЖИТЬ** — даёт привязку значения к биометрии (Keystore/Keychain), но 2 года без стабильного релиза; Windows — без биометрической привязки; дублирует flutter_secure_storage 11 (см. §5) |

### 1.5. Камера, детекция лица, штрихкоды

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| google_mlkit_face_detection | 0.15.1 | 2026-08-17 | MIT | **только Android (minSdk 21, compile/target 35), iOS 15.5+** | flutter-ml.dev (verified) | **ОТЛОЖИТЬ (R2) / опционально R1** — только детекция лица и углы головы; не распознаёт личность и не защищает от подделки (§6) |
| camera | 0.12.1 | 2026-09-03 | BSD-3-Clause | Android 24+, iOS 13+, Web | flutter.dev (verified) | **ВКЛЮЧИТЬ только вместе с ML Kit**; Windows в списке платформ не указан |
| mobile_scanner | 7.4.2 | 2026-09-14 | BSD-3-Clause | Android, iOS, macOS, Web; **Windows и Linux — не поддерживаются** | steenbakker.dev (verified) | **ВКЛЮЧИТЬ** (сканирование камерой на мобильных) |
| flutter_face_api (Regula) | 8.4.1655 | 9 дн. | MIT (плагин) | Android 7.0+/API 24, iOS 15+ | mobile.regulaforensics.com (verified) | коммерческий SDK — **ОТЛОЖИТЬ**, см. §6.4 |
| flutter_idensic_mobile_sdk_plugin (Sumsub) | 1.46.1 | 46 дн. | MIT (плагин) | Android, iOS | sumsub.com (verified) | коммерческий SDK — **ОТЛОЖИТЬ** |
| onfido_sdk | 11.1.0 | 18 дн. | MIT (плагин) | Android API 21+, iOS 13+ | onfido.com (verified) | коммерческий SDK — **ОТЛОЖИТЬ** |
| iproov_flutter | 6.1.0 | 10 мес. | не указана на pub.dev | Android, iOS | iproov.com (verified) | коммерческий SDK — **ОТЛОЖИТЬ** |

### 1.6. Сеть и данные

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| dio | 5.11.1 | 2026-09-04 | MIT | все | flutter.cn (verified) | **ВКЛЮЧИТЬ** — interceptors (auth, retry, logging), таймауты, отмена |
| dio_smart_retry | 7.0.1 | **24 мес.** | MIT | все | rodion-m.ru (verified) | **ОТКЛОНИТЬ** — 2 года без релизов; retry-интерсептор пишется самостоятельно (≈50 строк) под идемпотентные запросы |
| pretty_dio_logger | 1.4.0 | 2 года | MIT | все | codeness.ly (verified) | **ОТКЛОНИТЬ** — лог без фильтрации токенов/OTP; собственный интерсептор с редактированием секретов |
| freezed | 4.0.3 | 2026-10-17 | MIT | — (dev, генератор) | dash-overflow.net (verified), **FF** | **ВКЛЮЧИТЬ** (dev) — immutable-сущности, sealed-состояния, union для Result/Failure |
| freezed_annotation | 3.1.0 | 2025-07-02 | MIT | все | dash-overflow.net (verified) | **ВКЛЮЧИТЬ** — версий 4.x у пакета не существует; freezed 4.0.3 в своём pubspec зависит от `freezed_annotation: 3.1.0` (точный пин) `[ПОДТВЕРЖДЕНО: https://pub.dev/api/packages/freezed_annotation; https://pub.dev/api/packages/freezed, pubspec 4.0.3]` |
| json_serializable | 6.14.1 | 2026-07-30 | BSD-3-Clause | — (dev, генератор) | google.dev (verified) | **ВКЛЮЧИТЬ** (dev) — DTO слоя data |
| json_annotation | 4.12.0 | 2026-05-15 | BSD-3-Clause | все | google.dev (verified) | **ВКЛЮЧИТЬ** — json_serializable 6.14.1 требует `json_annotation >=4.12.0 <4.13.0` `[ПОДТВЕРЖДЕНО: https://pub.dev/api/packages/json_serializable, pubspec 6.14.1]` |
| retrofit + retrofit_generator | 4.10.0 | 2 мес. | MIT | все | mings.in (verified) | **ОТЛОЖИТЬ** — при 15–25 эндпоинтах R1 ручные Dio-клиенты проще и прозрачнее; пересмотреть при росте API |
| connectivity_plus | 7.3.2 | 2026-10-01 | BSD-3-Clause | все | fluttercommunity.dev (verified), **FF** | **ВКЛЮЧИТЬ** — только как сигнал «тип сети изменился»; README: «Connection type availability does not guarantee that there is an Internet access» → реальную доступность определяет ответ backend/health-check |
| cached_network_image | 4.0.4 | 2026-09-30 | MIT | все | baseflow.com (verified) | **ВКЛЮЧИТЬ** — фото товаров |
| flutter_cache_manager | 3.4.5 | 2026-09-19 | MIT | все | baseflow.com (verified) | **ВКЛЮЧИТЬ** — политика кэша (TTL, лимит), ключ кэша = id/контрольная сумма фото из 1С |
| flutter_svg | 2.3.0 | 2026-05-08 | MIT | все | flutter.dev (verified), **FF** | **ВКЛЮЧИТЬ** — иконки/логотип в SVG (если заказчик предоставит векторный логотип; сейчас есть только PNG) |
| equatable | 3.0.0 | 32 дн. | MIT | все | fluttercommunity.dev (verified) | **ОТКЛОНИТЬ** — freezed уже даёт `==`/`hashCode` |
| decimal | 3.2.6 | 2 мес. | Apache-2.0 | все | unverified uploader | **ОТКЛОНИТЬ для R1** — деньги хранить как `int` в тыйынах (1 сом = 100 тыйын) `[ТИПОВО, требует подтверждения правил округления 1С]`; `decimal` вернуть, если 1С отдаёт цены с >2 знаками |
| talker_flutter / talker_dio_logger | 5.1.20 | 2 мес. | MIT | все | frezycode.com (verified) | **ОТЛОЖИТЬ** — удобный экран логов для пилота, но не обязателен; базово — `package:logging` (dart.dev) с редактированием секретов |
| envied | 1.3.10 | 19 дн. | MIT | — | cinibulk.dev (verified) | **ОТКЛОНИТЬ** — README: обфускация «does NOT make them completely secure»; в приложении секретов быть не должно; конфигурация окружений через `--dart-define-from-file` |

### 1.7. Анимация, сплеш, ввод, i18n

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| rive (+ rive_native 0.1.11) | 0.14.11 (prerelease 0.15.0-dev.3) | 2026-08-03 | MIT (runtime) | все, включая Windows | rive.app (verified) | **ВКЛЮЧИТЬ** — персонаж авторизации со State Machine (inputs: idle/typing/checking/success/error) |
| lottie | 3.6.1 | 2026-09-18 | MIT | все | xaha.dev (verified) | **ОТКЛОНИТЬ для персонажа**, допустимо для одноразовых анимаций (галочка успеха) — нет state machine, только сегменты/контроллер |
| flutter_animate | 4.5.2 | **23 мес.** | BSD-3-Clause | все | gskinner.com (verified) | **ОТЛОЖИТЬ** — удобен, но 2 года без релизов; базовые переходы делать на `AnimatedSwitcher`/`implicit animations` Flutter |
| flutter_native_splash | 2.4.8 | 2026-05-29 | MIT | **Android, iOS, Web** (Windows не упомянут) | jonhanson.net (verified) | **ВКЛЮЧИТЬ** (dev, генератор) — нативный сплеш Android/iOS; на Windows нативного сплеша пакет не даёт |
| flutter_launcher_icons | 0.14.4 | 2025-06-10 | MIT | Android, iOS, Linux, macOS, Windows | fluttercommunity.dev (verified) | **ВКЛЮЧИТЬ** (dev, генератор иконок из «Logo Orange.png») |
| phone_numbers_parser | 9.0.28 | 2026-10-04 | MIT | все (pure Dart, «без channeling») | **unverified uploader** | **ВКЛЮЧИТЬ** — валидация/форматирование по метаданным libphonenumber без нативного кода → работает на Windows |
| mask_text_input_formatter | 2.9.0 | 2 года | MIT | все | unverified uploader | **ОТКЛОНИТЬ** — простая маска `+996 ### ### ###` реализуется собственным `TextInputFormatter` (≈40 строк), без зависимости |
| flutter_libphonenumber | 2.8.4 | 3 мес. | MIT | Android, iOS, macOS, Web; **Windows нет** | coutts-consulting.com (verified) | **ОТКЛОНИТЬ** — нативный плагин без Windows |
| intl | 0.20.3 | 2026-06-25 | BSD-3-Clause | все | dart.dev (verified) | **ВКЛЮЧИТЬ** (с flutter_localizations из SDK) |
| msix | 3.18.0 | 2026-06-27 | MIT | Windows | kremer.software (verified) | **ВКЛЮЧИТЬ** (dev) — упаковка Windows-сборки в MSIX |

### 1.8. Тестирование

| Пакет | Версия | Дата | Лицензия | Платформы | Статус | Решение |
|---|---|---|---|---|---|---|
| flutter_test, integration_test | SDK | — | BSD-3 | — | Flutter SDK | **ВКЛЮЧИТЬ** |
| mocktail | 1.0.5 | 2026-04-10 | MIT | — | felangel.dev (verified) | **ВКЛЮЧИТЬ** — моки без кодогенерации |
| alchemist | 0.14.1 | 2026-10-08 | MIT | Android, iOS, Linux, macOS, Windows | betterment.dev (verified) | **ВКЛЮЧИТЬ** — golden-тесты дизайн-системы (platform-agnostic goldens) |
| golden_toolkit | 0.15.0 | 3 года | BSD-3 | — | ebay.com, **DISCONTINUED** | **ОТКЛОНИТЬ** |
| patrol (+ patrol_cli) | 4.10.0 | 33 дн. | Apache-2.0 | Android, iOS, macOS, Web; **Windows нет** | leancode.co (verified) | **ОТЛОЖИТЬ** — нативная автоматизация (разрешения, системные диалоги биометрии) полезна в R2; требует отдельного native-setup |
| flutter_lints | 6.0.0 | 2025-05-27 | BSD-3 | — | flutter.dev (verified) | **ВКЛЮЧИТЬ** (уже в шаблоне) + riverpod_lint (как analyzer-плагин через `analysis_options.yaml`, см. §1.1; custom_lint не требуется) |

---

## 2. Управление состоянием и DI — решение: Riverpod 3

### 2.1. Факты
- Riverpod 3 (`flutter_riverpod` 3.4.3): единый `Ref`; `AutoDisposeNotifier`/`FamilyNotifier` удалены, всё через `Notifier`; аргументы family передаются через конструктор; автоматический retry упавших провайдеров с экспоненциальным backoff (настраивается на уровне контейнера и провайдера); `Ref.mounted`; `StateProvider`/`StateNotifierProvider`/`ChangeNotifierProvider` вынесены в `riverpod/legacy.dart`; ошибки провайдеров оборачиваются в `ProviderException`; `valueOrNull` переименован в `value`; `AsyncValue` — sealed, есть `isFromCache` и `progress` `[ПОДТВЕРЖДЕНО: https://riverpod.dev/docs/whats_new]`.
- Экспериментальные API Riverpod 3: **Mutations** и **Offline persistence** (`persist`, реализация `riverpod_sqflite` 0.4.7, unverified uploader, основана на sqflite — без Windows) — «API may change» `[ПОДТВЕРЖДЕНО: там же; https://pub.dev/packages/riverpod_sqflite]`. **Решение:** в R1 экспериментальные API не использовать; офлайн-персистентность делать через drift в слое data.
- Тестирование `[ПОДТВЕРЖДЕНО: https://riverpod.dev/docs/how_to/testing]`: `ProviderContainer.test()` на каждый тест; `overrides:` с `provider.overrideWith(...)`; в widget-тестах корень `ProviderScope(overrides: [...])`, доступ к контейнеру `tester.container()`; async — `container.read(provider.future)`; слежение за изменениями — `container.listen`; **мокать Notifier не рекомендуется** — мокаются зависимости (репозитории/use cases); при необходимости — подкласс (`extends`, не `implements`) и `overrideWith(MyNotifierMock.new)`.

### 2.2. Почему Riverpod, а не Bloc/Signals
| Критерий | Riverpod 3 | flutter_bloc 9.1.1 | signals 7.1.0 |
|---|---|---|---|
| DI (подмена репозиториев/use cases в тестах) | встроено (overrides) | нужен get_it/RepositoryProvider | нет |
| Шаблонный код на экран | Notifier + `@riverpod` | Event + State + Bloc | signal/computed |
| Статус | FF, релиз 44 дн. назад | FF, релиз 17 мес. назад | не FF |
| Производные/кэшируемые данные (фильтры каталога, итог корзины) | `ref.watch` граф, автоудаление | ручная композиция | computed |
| Пауза при скрытых экранах | автоматически (TickerMode) | нет | нет |
| Риск | breaking changes 2→3 уже пройдены; экспериментальные API не трогаем | стабилен | меньшее сообщество |

### 2.3. Маппинг на Clean Architecture
- **domain**: сущности (freezed), интерфейсы репозиториев, Use Cases — обычные классы `class CreateOrderUseCase { Future<Result<Order, Failure>> call(CreateOrderParams p) }`. Никаких импортов Riverpod/Flutter.
- **data**: реализации репозиториев, DTO (json_serializable), источники данных (Dio API, drift DAO, secure storage).
- **presentation**: `@riverpod class CartNotifier extends _$CartNotifier` вызывает use cases; UI через `ConsumerWidget`.
- **Провайдеры-«композиционные корни»** (`lib/core/di/*.dart` и `features/<f>/<f>_providers.dart`): `dioProvider`, `appDatabaseProvider`, `cartRepositoryProvider` (возвращает интерфейс `CartRepository`, реализация подменяется в тестах). Так Riverpod выступает DI-контейнером, а domain остаётся чистым.
- Правило линта: в `domain/**` запрещён импорт `package:flutter_riverpod`, `package:flutter/*`, `package:dio`, `package:drift` (проверять отдельным пакетом import-правил либо review-чеклистом) `[ТИПОВО: пакет для import-правил выбрать на этапе Foundation; riverpod_lint 3.x на custom_lint не основан, поэтому custom_lint в проект без отдельной причины не добавлять]`.

---

## 3. Навигация — решение: go_router + go_router_builder

- go_router 18.1.0, flutter.dev, FF, все платформы `[ПОДТВЕРЖДЕНО: pub.dev]`.
- Типизированные маршруты `[ПОДТВЕРЖДЕНО: https://pub.dev/documentation/go_router/latest/topics/Type-safe%20routes-topic.html; https://pub.dev/packages/go_router_builder]`: классы `extends GoRouteData` с `@TypedGoRoute<T>(path:)`, path-параметры → поля конструктора, генерация `dart run build_runner build`, агрегат `$appRoutes`, `@TypedShellRoute`/`ShellRouteData`, `$navigatorKey`/`$parentNavigatorKey`, `$extra`, route-level и глобальный `redirect`.
- Ограничения builder: `$extra` ломает deep-link/браузерную навигацию (на web не использовать); конверсия типов только `int`, enum, extension types. Типизированный stateful-shell поддерживается самим go_router 18.1.0: в API есть классы `StatefulShellRouteData` («Base class for supporting StatefulShellRoute»), `StatefulShellBranchData` и аннотация `TypedStatefulShellRoute({bool notifyRootObserver = true, List<TypedStatefulShellBranch<StatefulShellBranchData>> branches})` `[ПОДТВЕРЖДЕНО: https://pub.dev/documentation/go_router/latest/go_router/StatefulShellRouteData-class.html; https://pub.dev/documentation/go_router/latest/go_router/TypedStatefulShellRoute-class.html]`. README go_router_builder 4.5.0 описывает только `TypedShellRoute`/`ShellRouteData` и упоминает `StatefulShellRoute` лишь в разделе о дублирующихся путях `[ПОДТВЕРЖДЕНО: https://pub.dev/packages/go_router_builder]` → на этапе Foundation проверить только, что генератор 4.5.0 обрабатывает `@TypedStatefulShellRoute` (ожидается «да», т.к. аннотация входит в публичный API go_router) `[ТИПОВО: требует проверки сборкой]`.
- Применение в «Оптомстрой»:
  - `/splash` → `redirect` по состоянию сессии (`authStateProvider`) → `/login` | `/catalog`.
  - `StatefulShellRoute` с ветками `catalog`, `cart`, `customers`(кассир), `profile`: на телефоне — нижняя навигация, на планшете/Windows — боковая панель + постоянная корзина (один и тот же граф, разный layout по `Breakpoint`).
  - Карточка товара `/catalog/product/:productId?variant=` — параметры только в URL (без `$extra`), чтобы работала кнопка «назад» и восстановление после перезапуска.
  - `redirect` по ролям (продавец/кассир/админ): маршруты кассира недоступны продавцу — но это UX-ограничение, права проверяет сервер.
- auto_route 11.2.0 — рабочая альтернатива (кодогенерация, guards), отклонён из-за зависимости от одного издателя и большей «магии».

---

## 4. Локальное хранилище — решение: drift (SQLite)

### 4.1. Требования R1
1. Кэш каталога: десятки тысяч товаров + варианты + остатки по складам + цены; поиск по названию/артикулу/штрихкоду с задержкой ввода; фильтры; сортировка.
2. Корзина-черновик (переживает перезапуск), несколько отложенных заказов.
3. Избранное (товары; у кассира — клиенты) — серверное хранение + локальная копия.
4. Очередь офлайн-действий (создать заказ, добавить в избранное) с идемпотентными ключами и статусами.
5. Журнал синхронизации (время последнего успешного обмена, ошибки).
6. Windows + Android (+ iOS) из одной кодовой базы.

### 4.2. Почему drift
- Платформы: `NativeDatabase` (dart:ffi) — Android, iOS, Windows, Linux, macOS; Web — `WasmDatabase` `[ПОДТВЕРЖДЕНО: https://drift.simonbinder.eu/platforms/]`.
- Бандлинг SQLite: с sqlite3 3.0.0 — автоматически на мобильных; с drift 2.32.0 + sqlite3 3.x на десктопе «no further setup is required»; `sqlite3_flutter_libs` больше не нужен `[ПОДТВЕРЖДЕНО: там же]`. Это снимает главную историческую боль Windows-сборки.
- Фоновый изолят: `NativeDatabase.createInBackground` — SQL выполняется в отдельном изоляте, UI не блокируется; `computeWithDatabase` для массовых вставок (первичная загрузка каталога) `[ПОДТВЕРЖДЕНО: https://drift.simonbinder.eu/isolates/]`.
- Миграции схемы (`schemaVersion`, `MigrationStrategy`, экспорт схемы и тесты миграций) — критично для «обновлять приложение без потери черновиков» `[ТИПОВО: drift docs, требует проверки деталей на Foundation]`.
- Полнотекстовый поиск: SQLite FTS5 для названия/артикула; доступность FTS5 в бандле `package:sqlite3` `[ТИПОВО: по умолчанию компилируется с FTS5, требует проверки на сборке]`. Запасной вариант — обычные индексы + `LIKE` по нормализованному полю (для 20–50k строк приемлемо при индексе по артикулу/штрихкоду).
- Тестируемость: `NativeDatabase.memory()` в unit-тестах DAO без устройства.

### 4.3. Почему не остальные
- **isar**: стабильная 3.1.0+1 — 3 года без релиза; v4 «NOT READY FOR PRODUCTION» (README GitHub), 173 open issues. Для коммерческого POS с 3–5-летним горизонтом — неприемлемый риск.
- **isar_community 3.4.1**: активен, но наследует бинарное ядро и NoSQL-модель; команда маленькая. Отклонить, пересмотреть при R3+ только при доказанной потребности в скорости записи.
- **hive 2.2.3**: 4 года без релизов. **hive_ce 2.22.0**: живой, но key-value без запросов — не для каталога.
- **sqflite 2.4.4+2**: Android/iOS/macOS; Windows только через `sqflite_common_ffi`, нет типизации.
- **objectbox 5.3.2**: Apache-2.0 только на Dart-часть; ядро — бинарник `[НЕ ПОДТВЕРЖДЕНО]`; нет SQL.

### 4.4. Предварительная схема локальной БД (для 07_DATA_MODEL)
`products`, `product_variants`, `categories`, `warehouses`, `stock_balances`, `prices`, `product_images(meta)`, `favorites`, `cart_drafts`, `cart_items`, `outbox_actions(id, type, payload_json, idempotency_key, status, attempts, last_error, created_at)`, `sync_runs`, `app_meta(key,value)`. Денежные поля — `INTEGER` в тыйынах; количества — `INTEGER` в минимальных единицах + `unit_code` `[ТИПОВО: требует подтверждения единиц/упаковок в 1С у агента 2/7]`.

---

## 5. Безопасное хранение — flutter_secure_storage 11.2.0

`[ПОДТВЕРЖДЕНО: https://pub.dev/packages/flutter_secure_storage, README v11]`
- **Android**: по умолчанию `AndroidOptions()` — ключ-обёртка RSA/ECB/OAEPWithSHA-256AndMGF1Padding + AES/GCM/NoPadding для данных; варианты с биометрией — AES/GCM-ключ в Android KeyStore с опциональной или обязательной биометрией/PIN; `enforceBiometrics: true` требует API 28+; `strongBiometricOnly` полностью работает только на API 30+ (на API ≤29 device credential не принимается); Jetpack `encryptedSharedPreferences` — **deprecated, «no longer recommended»**; minSdk 23.
- **Известная проблема Android**: Auto Backup может привести к `java.security.InvalidKeyException: Failed to unwrap key` → в манифесте `allowBackup=false` (или исключить prefs из backup rules). Обязательно для R1.
- **iOS/macOS**: Keychain; accessibility `first_unlock` / `first_unlock_this_device` / `unlocked`(по умолчанию); нужен entitlement `keychain-access-groups`; при App Groups без имени группы «values appearing to be written successfully but never actually being written».
- **Windows**: README v11 механизм не описывает; по исходнику плагина `flutter_secure_storage_windows_plugin.cpp` (ветка develop) `[ПОДТВЕРЖДЕНО: https://github.com/juliansteenbakker/flutter_secure_storage/blob/develop/flutter_secure_storage_windows/windows/flutter_secure_storage_windows_plugin.cpp]`: **DPAPI (`CryptProtectData`) не используется**; схема гибридная — 16-байтовый AES-ключ хранится в Windows Credential Manager (`wincred.h`: `CredReadW`/`CredWriteW`/`CredDeleteW`, target `"key_" + <префикс>`, persist `CRED_PERSIST_LOCAL_MACHINE`), а сами значения шифруются AES-GCM через CNG (`bcrypt.h`: `BCryptEncrypt`/`BCryptDecrypt`, nonce 12 байт из `BCryptGenRandom`, формат файла: nonce + tag + ciphertext) и пишутся в файлы `<key>.secure` в папке `%APPDATA%\<CompanyName>\<ProductName>` (`SHGetKnownFolderPath(FOLDERID_RoamingAppData)` + CompanyName/ProductName из version-info исполняемого файла; при их отсутствии — `placeholder_company\placeholder_product`); Credential Manager также читается как fallback для значений, записанных старыми версиями. Требование сборки: C++ ATL (`atlstr.h`) из Visual Studio Build Tools. Следствия: (1) защита — на уровне учётной записи пользователя ОС (Credential Manager + файлы профиля), без аппаратного хранилища и без биометрии; (2) папка — **Roaming** AppData, т.е. при доменном roaming-профиле зашифрованные файлы могут реплицироваться, а ключ в Credential Manager — нет `[ТИПОВО: зависит от политики домена заказчика, требует проверки]`; (3) обязательно задать CompanyName/ProductName в `windows/runner/Runner.rc`, иначе данные лягут в `placeholder_company\placeholder_product`. Вывод для ТЗ без изменений: не хранить долгоживущие refresh-токены с большим TTL на общих POS-ПК; использовать короткие сессии и серверный отзыв устройства.
- **Web**: экспериментальный WebCrypto, «Use at your own risk», только HTTPS/localhost, значения в LocalStorage — **для web-таргета (если появится) токены считать незащищёнными**.
- Миграции: `migrateOnAlgorithmChange` по умолчанию true; вызвать `WidgetsFlutterBinding.ensureInitialized()` до использования.

Что хранить: access-token (короткий TTL), refresh-token, `device_id`, флаг «биометрия включена». **Не хранить**: OTP, пароли, секреты SMSPro/1С (их в приложении быть не должно вовсе).

---

## 6. Биометрия и «вход по лицу»

### 6.1. local_auth 3.0.2 — что реально даёт
`[ПОДТВЕРЖДЕНО: https://pub.dev/packages/local_auth; local_auth_android; local_auth_darwin; исходник local_auth_windows]`
- Возвращает только **булев результат** `authenticate()` (успех/ошибка `LocalAuthException` с кодами `noBiometricHardware`, `temporaryLockout`, `biometricLockout` и др.). Никакого криптоключа/токена не выдаёт.
- `canCheckBiometrics` — только наличие железа; `getAvailableBiometrics()` — что зарегистрировано; `BiometricType`: `face`, `fingerprint`, `weak`, `strong`; документация советует проверять «список непустой», а не конкретный тип — типы зависят от устройства/платформы.
- `biometricOnly: true` — только биометрия без PIN; **не поддерживается на Windows**.
- `persistAcrossBackgrounding` — система может отменить аутентификацию при уходе в фон.
- **Android**: `MainActivity` должен наследовать `FlutterFragmentActivity`; разрешение `android.permission.USE_BIOMETRIC`; минимум SDK 24. Под капотом — AndroidX BiometricPrompt: `BIOMETRIC_STRONG` = Class 3, `BIOMETRIC_WEAK` = Class 2, `DEVICE_CREDENTIAL`; `BIOMETRIC_STRONG|DEVICE_CREDENTIAL` недоступны на API ≤29 `[ПОДТВЕРЖДЕНО: https://developer.android.com/identity/sign-in/biometric-auth]`. **Лицо на Android доступно только если производитель реализовал Face Unlock через BiometricPrompt**; на многих устройствах лицо — Class 2 (weak) или вообще не отдаётся в BiometricPrompt. Гарантировать «вход по лицу» на Android нельзя — обещать «системную биометрию устройства (отпечаток или лицо, если доступно)».
- **iOS**: Face ID/Touch ID через LocalAuthentication; обязателен `NSFaceIDUsageDescription` в Info.plist.
- **Windows**: плагин вызывает `UserConsentVerifier.RequestVerificationForWindowAsync` (Windows Hello, через `IUserConsentVerifierInterop`) и `CheckAvailabilityAsync`; **не различает модальность** (лицо/отпечаток/PIN) — нативный `Authenticate` передаёт в callback `ErrorOr<AuthResult>` с одним из значений `kSuccess` (`UserConsentVerificationResult::Verified`), `kFailure`, `kNoHardware`, `kNotEnrolled`, `kDeviceBusy`, `kDisabledByPolicy`, `kUnavailable` — без указания, какой способ Windows Hello сработал; на уровне Dart API это сводится к `bool` / `LocalAuthException`; метода списка биометрий в нативном коде нет `[ПОДТВЕРЖДЕНО: raw.githubusercontent.com/flutter/packages/main/packages/local_auth/local_auth_windows/windows/local_auth_plugin.cpp]`. Т.е. на Windows Hello «вход по лицу» = «любой настроенный способ Windows Hello, включая PIN» `[ТИПОВО: поведение UserConsentVerifier с PIN — требует проверки на целевом ПК]`.

### 6.2. Привязка криптографического ключа к биометрии из Flutter
- local_auth — **нет**.
- flutter_secure_storage 11 — **да, на Android**: AES-ключ в KeyStore с требованием биометрии (`enforceBiometrics`, `strongBiometricOnly`); на iOS — Keychain accessibility, явная биометрическая access-control в README не описана `[НЕ ПОДТВЕРЖДЕНО: биометрический ACL на iOS в v11]`; на Windows — нет.
- biometric_storage 5.0.1 — да (Android KeyStore + androidx, iOS LocalAuthentication + Keychain), Windows — credential store **без** биометрии; 2 года без стабильного релиза, требует `Theme.AppCompat`.
- **Честный вывод для ТЗ**: кросс-платформенной аппаратной привязки токена к биометрии в Flutter нет. Для R1 принимаем модель «**биометрия как локальный замок UX**»: сервер выдаёт refresh-токен устройству; токен лежит в secure storage; перед его использованием приложение требует `local_auth.authenticate()`; на Android дополнительно включать биометрически-защищённую запись flutter_secure_storage (API 28+). Сервер хранит `device_id` и может отозвать устройство. Это не «аутентификация по биометрии» в криптографическом смысле — и так и должно быть записано в 09_AUTH_SMS_BIOMETRICS.

### 6.3. Детекция лица (ML Kit) — «сканирование при регистрации: прямо/влево/вправо/вверх»
`[ПОДТВЕРЖДЕНО: https://developers.google.com/ml-kit/vision/face-detection; https://pub.dev/packages/google_mlkit_face_detection; API-reference Face/FaceDetectorOptions]`
- Официальная формулировка Google: **«Note that the API detects faces, it does not recognize people.»** Нет эмбеддингов, нет сравнения лиц, нет liveness/anti-spoofing. Фото с экрана другого телефона ML Kit от живого лица не отличит.
- Платформы плагина 0.15.1: **только Android (minSdk 21) и iOS 15.5+**; «Web or any other platform is not supported» → на Windows-POS сканирование лица недоступно.
- Данные `Face`: `boundingBox: Rect`, `headEulerAngleX/Y/Z: double?`, `leftEyeOpenProbability`, `rightEyeOpenProbability`, `smilingProbability: double?` (при `enableClassification`), `trackingId: int?` (при `enableTracking`), `landmarks`, `contours`. Опции: `enableClassification`, `enableLandmarks`, `enableContours`, `enableTracking`, `minFaceSize` (0.1), `performanceMode` (fast/accurate).
- Семантика углов (из описания плагина): X — наклон вверх/вниз, Y — поворот влево/вправо, Z — наклон вбок. Сценарий «прямо → влево → вправо → вверх» реализуем как конечный автомат по `headEulerAngleY` (знак и порог) и `headEulerAngleX`; **пороги (например, |Y| ≥ 20–30°, X ≥ 15°) в официальной документации не заданы — подобрать эмпирически** `[НЕ ПОДТВЕРЖДЕНО: численные пороги]`. Требуется `camera` со `startImageStream` → `InputImage` (формат NV21/YUV420 на Android, BGRA8888 на iOS) `[ТИПОВО: по README плагина, требует проверки на устройствах]`.
- Лицензия: плагин MIT; нативные ML Kit SDK — условия Google ML Kit Terms `[ТИПОВО: требует проверки юридических условий Google для коммерческого использования]`.
- **Что это даёт бизнесу**: гарантию, что в кадре было лицо с поворотами и открытыми глазами (`eyeOpenProbability`), и набор кадров. Это **UX-ритуал и сбор фото профиля**, а не проверка личности. В ТЗ так и фиксировать: «серия фотографий не является защитой от подделки» (цитата требования заказчика, §7 мастер-промта).
- **Персональные данные**: фото лица — биометрические ПД. Без явного согласия, цели, срока хранения и защиты их хранить нельзя (мастер-промт §7). Рекомендация R1: **не сохранять кадры по умолчанию**; если нужно фото профиля — одно фото «прямо», с согласием, шифрование на сервере, срок хранения — отдельное решение заказчика (вопрос в 14_OPEN_QUESTIONS).

### 6.4. Коммерческие liveness/anti-spoofing SDK (если заказчик настаивает на проверке «живого лица»)
| Вендор | Flutter-пакет | Платформы | Что даёт | Условия |
|---|---|---|---|---|
| Regula Face SDK | flutter_face_api 8.4.1655 (9 дн.) | Android 7+/API 24, iOS 15+ | «face matching, recognition and liveness detection» | плагин MIT, условия SDK — у вендора `[НЕ ПОДТВЕРЖДЕНО: стоимость/лицензия]` |
| Sumsub | flutter_idensic_mobile_sdk_plugin 1.46.1 | Android, iOS | KYC-SDK (документы, liveness) | аккаунт Sumsub `[ТИПОВО]` |
| Onfido | onfido_sdk 11.1.0 | Android API 21+, iOS 13+ | Smart Capture: документ, лицо (photo/video/motion) | аккаунт Onfido, «contact client-support@onfido.com to obtain a live API token», billing details перед go-live `[ПОДТВЕРЖДЕНО: pub.dev]` |
| iProov | iproov_flutter 6.1.0 (10 мес.) | Android, iOS | Dart-обёртка над нативными SDK, события захвата | регистрация в iPortal, API credentials `[ПОДТВЕРЖДЕНО: pub.dev]` |
| FaceTec | Flutter-плагина на сайте не указано | iOS 12+, Android 5+, web, server SDK | 3D liveness, 1:1/1:N матчинг; заявлены iBeta ISO/IEC 30107-3 L1/L2 | коммерческий, помесячно за проверку с минимальным платежом `[ПОДТВЕРЖДЕНО: https://www.facetec.com/, заявления вендора не проверены независимо]` |

Все пять — **ни один не поддерживает Windows**; все требуют договора и серверной части (верификация на сервере вендора или on-prem). Для оптового магазина в KG это отдельный бюджет и юридическая проверка (трансграничная передача биометрических ПД).

### 6.5. Что честно обещать в Release 1
1. Вход по телефону + OTP (SMSPro, серверная сторона) — основной.
2. «Быстрый вход» через системную биометрию устройства (отпечаток/лицо/Windows Hello — что настроено в ОС) + безопасно хранимый токен, с откатом на OTP.
3. Экран «сканирование лица» при регистрации — **опционально, только Android/iOS**, как guided-захват с ML Kit (прямо/влево/вправо/вверх), без идентификации и без anti-spoofing; на Windows и неподдерживаемых устройствах — шаг пропускается с сообщением. Рекомендация: вынести в R2 или заменить на «фото профиля» до решения о коммерческом liveness-SDK.
4. Не обещать: распознавание личности по лицу, защиту от фото/видео-подделки, Face Unlock на всех Android.

---

## 7. Сканирование штрихкодов

- **Камера (мобильные)**: mobile_scanner 7.4.2 — Android, iOS, macOS, Web; **Windows/Linux не поддерживаются**; Android: ML Kit bundled по умолчанию (+3–10 МБ), unbundled через `dev.steenbakker.mobile_scanner.useUnbundled=true` (+~600 КБ, модель догружается Google Play Services); форматы: EAN-8/13, UPC-A/E, Code 39/93/128, ITF, QR, DataMatrix, PDF417, Aztec, Codabar `[ПОДТВЕРЖДЕНО: pub.dev + GitHub README]`. minSdk в README не указан `[ТИПОВО: совместим с minSdk 24]`.
- **USB/Bluetooth-сканеры как HID-клавиатура (Windows и Android)**:
  - `RawKeyboard` **deprecated**: «This class is deprecated and will be removed at a future date. The HardwareKeyboard class is its replacement» `[ПОДТВЕРЖДЕНО: https://api.flutter.dev/flutter/services/RawKeyboard-class.html]`.
  - `HardwareKeyboard.instance.addHandler(KeyEvent)` — глобальный обработчик всех аппаратных клавиш (`KeyDownEvent`/`KeyRepeatEvent`/`KeyUpEvent`), снимать через `removeHandler` `[ПОДТВЕРЖДЕНО: https://api.flutter.dev/flutter/services/HardwareKeyboard-class.html]`; `KeyboardListener(focusNode:, onKeyEvent:)` — виджетный вариант, требует фокуса `[ПОДТВЕРЖДЕНО: api.flutter.dev/flutter/widgets/KeyboardListener-class.html]`.
  - Проектное решение (`core/hardware/scanner_wedge_service.dart`): глобальный handler через `HardwareKeyboard`, буферизация символов, детекция «ввод быстрее N мс между клавишами + суффикс Enter/Tab» → событие `BarcodeScanned(code)` в поток; UI подписывается (каталог → поиск/добавление в корзину). Сканер настраивается на суффикс Enter (стандартно). Когда фокус в текстовом поле поиска — ввод и так попадёт в поле; handler должен не дублировать. `[ТИПОВО: HID-сканеры на Windows и Android (USB OTG/BT HID) видны как клавиатура, требует проверки с реальной моделью сканера заказчика]`.
  - Открытый вопрос к заказчику: модель сканера, режим (HID/serial), суффикс, кодировка кириллицы не требуется (цифровые EAN).

---

## 8. Сеть и данные

- **dio 5.11.1**: interceptors — `AuthInterceptor` (Bearer, refresh с single-flight и очередью), `RetryInterceptor` собственный (только идемпотентные GET и POST с `Idempotency-Key`, backoff 1-2-4 c, не ретраить 4xx), `LoggingInterceptor` с маскированием `Authorization`, телефонов, OTP. `connectTimeout`/`receiveTimeout` явно (слабый интернет). `CancelToken` для поиска с debounce.
- **freezed 4.0.3 + json_serializable 6.14.1**: domain-сущности — freezed без JSON; DTO в data — freezed + `@JsonSerializable` или только json_serializable; маппинг DTO→Entity в data. `Result<T, Failure>` — sealed-класс freezed (`Success`/`FailureResult`), `Failure` — sealed (`NetworkFailure`, `ServerFailure(code, message)`, `AuthFailure`, `ValidationFailure`, `ConflictFailure(priceChanged/stockChanged)`, `UnknownFailure`).
- **retrofit** — отложить (см. таблицу).
- **connectivity_plus 7.3.2** — только триггер для повторной синхронизации/outbox; «онлайн» определяется успешным `GET /health` или любым успешным запросом.
- **cached_network_image 4.0.4 + flutter_cache_manager 3.4.5**: собственный `CacheManager(Config('product_images', stalePeriod: 30d, maxNrOfCacheObjects: N))`; ключ кэша — URL с версией/контрольной суммой фото из 1С (чтобы не перекачивать каждые 30 мин, см. мастер-промт §4); заглушка при отсутствии фото — своя, никогда не фото другого товара.
- **flutter_svg 2.3.0** — иконки; логотип в проекте только PNG («Logo Orange.png») → запросить SVG у заказчика.
- **Конфигурация окружений**: `--dart-define-from-file=config/dev.json|prod.json` (API base URL, флаги), без секретов. envied отклонён.

---

## 9. Анимация персонажа и splash

- **rive 0.14.11** (runtime MIT, зависит от `rive_native` 0.1.11; Windows поддерживается обоими рендерерами) `[ПОДТВЕРЖДЕНО: pub.dev]`. State Machine с входами `bool isTyping`, `bool isChecking`, `trigger success`, `trigger error`, `number lookX` (взгляд на поле) — соответствует требованию «персонаж реагирует на состояние». Редактор Rive `[ПОДТВЕРЖДЕНО: https://rive.app/pricing]`: Free $0 — экспорт **со сплеш-экраном Rive (watermark)**, 3 файла, 1 проект; Cadet $9/seat/мес — без сплеша; Voyager $32. → Для коммерческого продукта нужен минимум Cadet на время производства ассета либо заказ ассета у дизайнера (вопрос в 14_OPEN_QUESTIONS). Статус рантайма — верифицированный издатель, но релиз 0.x и крупная миграция на rive_native — риск API-изменений `[ТИПОВО]`.
- **lottie 3.6.1** — для одноразовых анимаций (зелёная галочка успеха, пустые состояния). Нет state machine (только сегменты через `AnimationController`).
- **flutter_animate 4.5.2** — 23 мес. без релизов → отложить; переходы на стандартных `AnimatedSwitcher`/`AnimatedContainer`/`Hero`.
- **Splash**: flutter_native_splash 2.4.8 — Android/iOS/Web; Android 12+ только цвет фона + иконка (1152×1152 без фона / 960×960 с фоном, ~1/3 иконки маскируется), брендинг 800×320, не показывается при запуске из уведомления `[ПОДТВЕРЖДЕНО: pub.dev README]`. Windows — нативного сплеша нет; первый кадр Flutter-окна = Rive/Flutter-анимация логотипа. Правило мастер-промта: не задерживать пользователя — анимация ≤ 800 мс и параллельная проверка сессии.
- Логотип: в ресурсах — оранжевый (кольцо «C» + шестиугольник + стрелка), на макетах — синий «дом с краном». Какой использовать в splash/иконке — вопрос заказчика (передано агенту 4).

---

## 10. Ввод телефона +996

- **phone_numbers_parser 9.0.28** — pure Dart, все платформы (включая Windows), метаданные Google libphonenumber: `PhoneNumber.parse()`, валидация по типу (mobile/fixed), `formatNsn()` `[ПОДТВЕРЖДЕНО: https://pub.dev/packages/phone_numbers_parser]`. Издатель не верифицирован — зафиксировать версию (`^9.0.28`) и проверить лицензию MIT при аудите зависимостей.
- flutter_libphonenumber — нет Windows → отклонить. mask_text_input_formatter — маска пишется своими силами.
- Формат KG: международный код `+996`, национальный номер 9 цифр, отображение `+996 XXX XXX XXX`, хранение/передача на сервер — E.164 `+996XXXXXXXXX` `[ТИПОВО: по метаданным libphonenumber для региона KG, требует проверки операторских диапазонов у заказчика]`. Код страны показывать фиксированным префиксом (флаг + «+996»), без выбора страны в R1; ввод только цифр (`TextInputType.phone`, `FilteringTextInputFormatter.digitsOnly`); вставка «0XXX…»/«996…»/«+996…» нормализуется.
- Серверная проверка существования аккаунта и анти-перебор — за пределами клиента (агент 5/6).

---

## 11. Интернационализация

`[ПОДТВЕРЖДЕНО: https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization]`
- `flutter_localizations` (SDK) + `intl` 0.20.3; `flutter: generate: true`; `l10n.yaml` (`arb-dir: lib/l10n`, `template-arb-file: app_ru.arb`, `output-localization-file: app_localizations.dart`, `nullable-getter: false`); генерация на `flutter pub get`/`flutter gen-l10n`; `AppLocalizations.delegate` + `GlobalMaterialLocalizations.delegates`; плюрали/select/плейсхолдеры/форматы чисел и дат в ARB.
- Политика: **все** строки UI только через `AppLocalizations` (lint-правило/ревью: запрет строковых литералов в виджетах, кроме технических). Основной `ru`; каркас для `ky` и `en` — пустые ARB с fallback на ru. Поддержка `ky` в `GlobalMaterialLocalizations` `[ТИПОВО: Flutter поставляет локализацию Material для ky, требует проверки на Foundation; иначе — кастомный делегат, что документация допускает]`.
- Форматы: сом — `NumberFormat.currency(locale: 'ru', symbol: 'сом', decimalDigits: 2)` `[ТИПОВО: символ/написание согласовать с 1С-печатными формами]`; даты — `DateFormat.yMd('ru')`.

---

## 12. Тестирование (коротко)

| Слой | Инструмент | Что проверяем |
|---|---|---|
| domain (use cases, сущности) | flutter_test/`test`, mocktail | чистые unit-тесты без Flutter; моки интерфейсов репозиториев |
| data (репозитории, DAO, API) | drift `NativeDatabase.memory()`, Dio `HttpClientAdapter`-мок/mocktail | маппинг DTO, миграции схемы (drift schema tests), outbox, кэш |
| presentation (Notifier) | `ProviderContainer.test(overrides:)`, `container.listen` | переходы состояний корзины/авторизации/синка |
| виджеты | `testWidgets` + `ProviderScope(overrides:)`, `tester.container()` | экраны в состояниях loading/empty/error/offline |
| golden | alchemist 0.14.1 | компоненты дизайн-системы, адаптивные брейкпоинты (phone/tablet/desktop) |
| интеграционные | integration_test (SDK) | сквозные сценарии на Windows-десктопе и Android-эмуляторе: вход OTP (mock backend), поиск, корзина, заказ |
| нативная автоматизация | patrol — отложено (R2) | системные диалоги биометрии/разрешений |
| статика | `flutter analyze`, flutter_lints 6 + riverpod_lint (analyzer-плагин в `analysis_options.yaml`), `dart format --set-exit-if-changed` | CI-гейт |

golden_toolkit — discontinued, не использовать.

---

## 13. Платформы и сборки

**Сборки ни одной платформы в рамках ЭТАПА 1 не выполнялись** (запрет разработки). Ниже — требования.

| Платформа | Требования | Статус на этой машине |
|---|---|---|
| **Windows** | Windows 10/11 x64/Arm64; Visual Studio (не VS Code) с workload **«Desktop development with C++»** (`Microsoft.VisualStudio.Workload.NativeDesktop`) `[ПОДТВЕРЖДЕНО: https://docs.flutter.dev/platform-integration/windows/setup]`; для flutter_secure_storage — C++ ATL; дистрибуция: MSIX (пакет `msix`, для self-hosted — сертификат `.pfx` от доверенного CA) или zip с `.exe` + `.dll` + `data/` + VC++ runtime (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`) `[ПОДТВЕРЖДЕНО: https://docs.flutter.dev/platform-integration/windows/building]` | VS 2022 17.14 + Windows 10 SDK 26100 — `flutter doctor [√]`. Сборка **не проверена** |
| **Android** | minSdk **24** (Flutter default; local_auth 24+; ML Kit 21+; secure_storage 23+; camera 24+) — повышать не требуется; compile/target 36 (ML Kit-плагин заявляет 35 — совместимо); `FlutterFragmentActivity` для local_auth; разрешения `USE_BIOMETRIC`, `CAMERA`, `INTERNET`; `allowBackup=false`; подпись release-ключом (сейчас debug); при unbundled ML Kit — зависимость от Google Play Services (на устройствах без GMS — bundled) | SDK 36 установлен, лицензии не приняты, физического устройства нет. Сборка **не проверена** |
| **iOS** | macOS + Xcode (версию для Flutter 3.38 см. docs.flutter.dev/platform-integration/ios/setup `[ТИПОВО]`), Apple Developer Program для подписи/TestFlight; deployment target поднять с 13.0 до **15.5** (ML Kit) или 15.0 (минимум Flutter) ; Info.plist: `NSFaceIDUsageDescription`, `NSCameraUsageDescription`; entitlement keychain-access-groups | **Нет macOS** → сборка невозможна на этой машине; нужен Mac/CI (Codemagic/GitHub Actions macOS) `[ТИПОВО]` |
| **Web** | не в R1 (secure storage experimental, нет биометрии/ML Kit) | — |

Матрица возможностей по платформам (R1):

| Функция | Android | iOS | Windows |
|---|---|---|---|
| Каталог/корзина/заказ (офлайн-кэш drift) | да | да | да |
| OTP-вход | да | да | да |
| Системная биометрия (local_auth) | отпечаток / лицо (если OEM) | Face ID / Touch ID | Windows Hello (любой способ, incl. PIN) |
| Биометрически защищённое хранилище | да (API 28+) | частично `[НЕ ПОДТВЕРЖДЕНО]` | нет |
| Сканирование камерой (mobile_scanner) | да | да | **нет** |
| HID-сканер (клавиатура) | да (USB OTG/BT) | ограниченно `[ТИПОВО]` | да |
| Детекция лица ML Kit | да (API 21+) | да (15.5+) | **нет** |
| Нативный splash | да | да | нет (in-app) |

---

## 14. Структура каталогов `lib/` и диаграмма зависимостей

### 14.1. Дерево (Release 1)
```
lib/
  main.dart                      # bootstrap: ensureInitialized, ProviderScope, runApp
  app/
    app.dart                     # MaterialApp.router, темы, локализация
    router/                      # go_router: app_router.dart, routes.dart (+ .g.dart), guards
    bootstrap.dart               # инициализация БД, secure storage, конфигурации
  core/                          # не знает о фичах
    config/        app_config.dart (dart-define), environment.dart
    error/         failure.dart (sealed), result.dart, error_mapper.dart
    network/       dio_client.dart, interceptors/{auth,retry,logging}.dart, api_paths.dart
    database/      app_database.dart (drift), tables/, migrations/, daos/ (общие)
    storage/       secure_storage.dart, key_value_store.dart
    sync/          outbox_queue.dart, sync_scheduler.dart, sync_status.dart
    hardware/      scanner_wedge_service.dart (HID), biometric_service.dart (local_auth)
    connectivity/  connectivity_watcher.dart
    l10n/          (генерируемый app_localizations.dart + ARB в lib/l10n/)
    utils/         money.dart (тыйыны), phone.dart (+996), debouncer.dart, logger.dart
    di/            core_providers.dart (dio, db, storage, clock)
  design_system/                 # токены и компоненты без бизнес-логики
    tokens/        colors.dart, typography.dart, spacing.dart, radii.dart, breakpoints.dart
    theme/         app_theme.dart (light/dark)
    components/    buttons/, inputs/, cards/, product_card.dart, quantity_stepper.dart,
                   skeletons/, empty_state.dart, error_state.dart, sync_badge.dart,
                   adaptive_scaffold.dart (phone/tablet/desktop)
    animations/    character_rive.dart (обёртка State Machine), success_check.dart
  features/
    splash/        presentation/
    auth/          domain/{entities,repositories,usecases}  data/{models,datasources,repositories}  presentation/{screens,widgets,notifiers}
    registration/  domain/ data/ presentation/   (+ face_capture/ подпапка, только Android/iOS)
    catalog/       domain/ data/ presentation/   (категории, список, поиск, фильтры, сортировка)
    product_details/ domain/ data/ presentation/ (варианты, фото, остатки по складам)
    cart/          domain/ data/ presentation/   (черновики, итог, предупреждения о цене/остатке)
    checkout/      domain/ data/ presentation/   (шаги Клиент/Получение/Оплата/Завершение из макета IMG_7090)
    favorites/     domain/ data/ presentation/
    customers/     domain/ data/ presentation/   (кассир: поиск, карточка, долги — только чтение из 1С)
    transactions/  domain/ data/ presentation/
    profile/       domain/ data/ presentation/
    settings/      presentation/
    sync_status/   presentation/ (+ использует core/sync)
test/
  unit/ (domain, data), widget/, golden/, integration_test/
```
Правило: `features/<a>` не импортирует `features/<b>` напрямую. Общее (например, `Product` нужен каталогу, корзине и избранному) выносится в `features/catalog/domain` как «владелец» сущности, а остальные зависят от **domain**-слоя владельца, не от data/presentation; при росте — выделить `shared_domain/`. Межфичевые события (товар добавлен в корзину → бейдж) — через Riverpod-провайдеры, а не через прямые вызовы.

### 14.2. Диаграмма зависимостей слоёв
```
            ┌──────────────────────────────┐
            │  presentation (UI, Notifier) │  flutter, flutter_riverpod, go_router, rive, design_system
            └──────────────┬───────────────┘
                           │ вызывает Use Cases, получает Entities / Failure
                           ▼
            ┌──────────────────────────────┐
            │  domain (Entities, UseCases, │  только dart + freezed; НЕТ flutter/dio/drift/riverpod
            │  Repository interfaces)      │
            └──────────────▲───────────────┘
                           │ реализует интерфейсы
            ┌──────────────┴───────────────┐
            │  data (RepositoryImpl, DTO,  │  dio, drift, secure storage, json_serializable
            │  remote/local datasources)   │
            └──────────────┬───────────────┘
                           │
            ┌──────────────▼───────────────┐
            │  core (network, db, sync,    │  не зависит от features
            │  storage, hardware, config)  │
            └──────────────────────────────┘
   design_system ──► используется только presentation; не зависит от features/core (кроме l10n/tokens)
   Стрелки направлены внутрь: presentation → domain ← data → core. Domain не знает ни о ком.
   Связывание реализаций с интерфейсами — в providers (композиционный корень), а не в domain.
```

### 14.3. Модули Release 1 (решение по списку мастер-промта)
| Модуль из мастер-промта | R1 | Комментарий |
|---|---|---|
| Authentication (OTP, биометрия) | **да** | `features/auth` |
| User Profile / Registration | **да** | `features/registration`, `features/profile`; face_capture — опционально Android/iOS |
| Catalog + Search & Filters | **да** | один модуль `catalog` (поиск/фильтры — его presentation/domain), отдельный модуль не нужен |
| Inventory (остатки/склады) | **да, внутри catalog/product_details** | отдельный модуль не выделяется до появления складских операций |
| Cart | **да** | |
| POS / Sales (checkout) | **да — оформление заказа** | кассовая продажа/фискализация — только после подтверждения процессов (агент 7); в R1 заказ создаётся в 1С «на согласование» (макет IMG_7090) |
| Customers | **да (чтение)** | карточка клиента, история, долг из 1С — по ролям |
| Debts & Discounts | **частично** | отображение долга и скидки в %; правила — на сервере; модуль не отдельный, внутри customers/cart |
| Favorites | **да** | |
| OneC Integration | **нет в клиенте** | интеграция на backend; клиент имеет только `sync_status` + outbox |
| Transactions | **да (список/детали)** | |
| Notifications (push) | **нет** | R2; в R1 — in-app баннеры ошибок синка |
| Settings | **да (минимум)** | язык, тема, устройство/сканер, выход |
| Reports/analytics, Returns (возвраты) | **нет** | R2+ (возврат — после подтверждения документооборота 1С) |

Добавление нового модуля в R2: новая папка `features/<name>/{domain,data,presentation}` + регистрация маршрутов в `app/router` + провайдеры; существующие модули не меняются (кроме владельца общей сущности, если она расширяется).

---

## 15. Итоговый список зависимостей R1 (черновик `pubspec.yaml`, НЕ применён к проекту)

```yaml
# dependencies (версии — pub.dev на 2026-10-18; при старте разработки перепроверить `flutter pub outdated`)
flutter_riverpod: ^3.4.3
riverpod_annotation: ^4.0.7
go_router: ^18.1.0
drift: ^2.35.2
drift_flutter: ^0.3.1
sqlite3: ^3.7.1
shared_preferences: ^2.5.6
flutter_secure_storage: ^11.2.0
local_auth: ^3.0.2
dio: ^5.11.1
freezed_annotation: ^3.1.0      # [ПОДТВЕРЖДЕНО: pub.dev — последняя 3.1.0 (2025-07-02); freezed 4.0.3 пинит freezed_annotation 3.1.0; версий 4.x не существует]
json_annotation: ^4.12.0         # [ПОДТВЕРЖДЕНО: pub.dev — последняя 4.12.0 (2026-05-15); json_serializable 6.14.1 требует >=4.12.0 <4.13.0]
connectivity_plus: ^7.3.2
cached_network_image: ^4.0.4
flutter_cache_manager: ^3.4.5
flutter_svg: ^2.3.0
rive: ^0.14.11
lottie: ^3.6.1                   # опционально
mobile_scanner: ^7.4.2
phone_numbers_parser: ^9.0.28
intl: ^0.20.3
flutter_localizations: {sdk: flutter}
# только при включении face_capture в R1 (Android/iOS):
# google_mlkit_face_detection: ^0.15.1
# camera: ^0.12.1

# dev_dependencies
build_runner: ^2.17.1
riverpod_generator: ^4.0.9
riverpod_lint: ^3.1.9             # плюс в analysis_options.yaml блок `plugins:` → `riverpod_lint: ^3.1.9` (analysis_server_plugin) [ПОДТВЕРЖДЕНО: README riverpod_lint]
# custom_lint — НЕ нужен: riverpod_lint 3.x реализован на analysis_server_plugin и custom_lint не использует [ПОДТВЕРЖДЕНО: pubspec riverpod_lint 3.1.9 на pub.dev]
go_router_builder: ^4.5.0
drift_dev: ^2.35.1                # [ПОДТВЕРЖДЕНО: pub.dev — последняя 2.35.1 (2026-09-30), допускает drift >=2.30.0 <2.36.0]
freezed: ^4.0.3
json_serializable: ^6.14.1
mocktail: ^1.0.5
alchemist: ^0.14.1
flutter_native_splash: ^2.4.8
flutter_launcher_icons: ^0.14.4
msix: ^3.18.0
flutter_lints: ^6.0.0
integration_test: {sdk: flutter}
```
Совместимость этого набора с Flutter 3.38.7/Dart 3.10.7 между собой **не проверялась `pub get`** (запрет изменения проекта) → первая задача этапа Foundation: `flutter pub get` + `flutter analyze` + сборка Windows и Android.

---

## 16. Открытые вопросы (для 14_OPEN_QUESTIONS)
1. Какие платформы обязательны для R1: Windows-POS + Android-планшеты? iOS нужен? (определяет необходимость Mac/CI.)
2. Модель и режим штрих-сканеров в магазине (HID/USB/Bluetooth, суффикс).
3. Нужно ли «сканирование лица» в R1 вообще, или достаточно системной биометрии; если нужно — готов ли заказчик к бюджету на коммерческий liveness-SDK и юридическому согласию на обработку биометрических ПД.
4. Хранить ли фото лица (где, сколько, согласие).
5. Какой логотип основной (оранжевый из ресурсов или синий из макетов); есть ли SVG.
6. Бюджет на Rive (Cadet $9/seat) или заказ анимации персонажа.
7. Единицы измерения/упаковки и точность цен в 1С (влияет на `int`-тыйыны vs `decimal`).
8. Ожидаемый размер каталога (число товаров/вариантов/фото) для оценки первичной загрузки и FTS.
9. Общие POS-ПК на Windows: один пользователь ОС на несколько продавцов? (влияет на политику хранения токенов и TTL сессии.)
10. Требуется ли web-таргет в будущем (ограничения secure storage/биометрии).

## 17. Источники (дата обращения 2026-10-18)
- pub.dev страницы всех пакетов из §1 (`https://pub.dev/packages/<name>`), API-reference `https://pub.dev/documentation/google_mlkit_face_detection/latest/...`, `https://pub.dev/documentation/go_router/latest/topics/Type-safe%20routes-topic.html`
- https://riverpod.dev/docs/whats_new ; https://riverpod.dev/docs/how_to/testing
- https://drift.simonbinder.eu/platforms/ ; https://drift.simonbinder.eu/isolates/
- https://developers.google.com/ml-kit/vision/face-detection
- https://developer.android.com/identity/sign-in/biometric-auth
- https://raw.githubusercontent.com/flutter/packages/main/packages/local_auth/local_auth_windows/windows/local_auth_plugin.cpp
- https://github.com/juliansteenbakker/flutter_secure_storage/blob/develop/flutter_secure_storage_windows/windows/flutter_secure_storage_windows_plugin.cpp
- pub.dev API (точные даты релизов и pubspec-ограничения): `https://pub.dev/api/packages/<name>` для freezed, freezed_annotation, json_serializable, json_annotation, drift_dev, riverpod_lint, custom_lint и всех включённых пакетов §1
- https://pub.dev/documentation/go_router/latest/go_router/StatefulShellRouteData-class.html ; https://pub.dev/documentation/go_router/latest/go_router/TypedStatefulShellRoute-class.html ; https://pub.dev/packages/go_router_builder (README)
- https://pub.dev/packages/sqlite3_flutter_libs ; https://pub.dev/packages/riverpod_lint (README, раздел установки)
- https://raw.githubusercontent.com/juliansteenbakker/mobile_scanner/master/README.md
- https://github.com/isar/isar
- https://docs.flutter.dev/reference/supported-platforms ; https://docs.flutter.dev/platform-integration/windows/setup ; https://docs.flutter.dev/platform-integration/windows/building ; https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization
- https://api.flutter.dev/flutter/services/RawKeyboard-class.html ; https://api.flutter.dev/flutter/services/HardwareKeyboard-class.html ; https://api.flutter.dev/flutter/widgets/KeyboardListener-class.html
- https://rive.app/pricing ; https://www.facetec.com/ ; https://www.iproov.com/
- Локально: `flutter --version`, `flutter doctor -v`, файлы шаблона проекта, `FlutterExtension.kt` из Flutter SDK.

---

## 18. Журнал проверки (правки по замечаниям независимого проверяющего, 2026-10-18)

Все проверки выполнены по `https://pub.dev/api/packages/<name>` (поле `published`, pubspec зависимостей), страницам pub.dev и исходникам на GitHub; дата обращения 2026-10-18.

| # | Серьёзность | Место | Что исправлено | Источник |
|---|---|---|---|---|
| 1 | major | §1.6 таблица; §15 pubspec | Строка «freezed + freezed_annotation 4.0.3» разделена: **freezed 4.0.3 (2026-10-17, dev)** и **freezed_annotation 3.1.0 (2025-07-02)**. Версий freezed_annotation 4.x не существует; freezed 4.0.3 пинит `freezed_annotation: 3.1.0`. В §15 заменено `^4.0.0` → `^3.1.0`, статус [ПОДТВЕРЖДЕНО] | https://pub.dev/api/packages/freezed_annotation ; https://pub.dev/api/packages/freezed |
| 2 | minor | §1.6 таблица; §15 pubspec | Строка json_serializable разделена на **json_serializable 6.14.1 (2026-07-30, dev)** и **json_annotation 4.12.0 (2026-05-15)**; в §15 `^4.9.0` → `^4.12.0` (json_serializable 6.14.1 требует `>=4.12.0 <4.13.0`), статус [ПОДТВЕРЖДЕНО] | https://pub.dev/api/packages/json_annotation ; https://pub.dev/api/packages/json_serializable |
| 3 | minor | §1.3, строка sqlite3_flutter_libs | «DISCONTINUED» заменено на «obsolete / EOL (0.6.0+eol)»; приведены дословные формулировки pub.dev: «Not used anymore, update to version 3.x of package:sqlite3 instead», «This package relates to version 2.x of `package:sqlite3`, and is obsolete after upgrading», «Starting from version `0.6.0`, this package no longer does anything» | https://pub.dev/packages/sqlite3_flutter_libs |
| 4 | minor | §6.1, пункт Windows | Переформулировано: нативный `Authenticate` передаёт `ErrorOr<AuthResult>` (`kSuccess`, `kFailure`, `kNoHardware`, `kNotEnrolled`, `kDeviceBusy`, `kDisabledByPolicy`, `kUnavailable`) без указания модальности; `bool`/`LocalAuthException` — уровень Dart API | local_auth_plugin.cpp (flutter/packages, main) |
| 5 | minor | §3, «Ограничения builder» | Статус изменён на [ПОДТВЕРЖДЕНО]: в API go_router 18.1.0 есть `StatefulShellRouteData`, `StatefulShellBranchData` и аннотация `TypedStatefulShellRoute(branches:, notifyRootObserver:)`. README go_router_builder 4.5.0 их не описывает (упоминает `StatefulShellRoute` только в разделе о дублирующихся путях) → оставлена проверка на Foundation только для обработки аннотации генератором [ТИПОВО] | https://pub.dev/documentation/go_router/latest/go_router/StatefulShellRouteData-class.html ; .../TypedStatefulShellRoute-class.html ; https://pub.dev/packages/go_router_builder |
| 6 | minor | §5, пункт Windows | Прочитан исходник `flutter_secure_storage_windows_plugin.cpp` (develop). Предположение о DPAPI/`CryptProtectData` **не подтвердилось и удалено**. Фактический механизм: AES-ключ в Windows Credential Manager (`CredReadW`/`CredWriteW`, `CRED_PERSIST_LOCAL_MACHINE`) + значения в файлах `<key>.secure` под `%APPDATA%\<CompanyName>\<ProductName>`, шифрование AES-GCM через CNG (`BCryptEncrypt`/`BCryptDecrypt`). Статус [ПОДТВЕРЖДЕНО]; добавлены следствия (Roaming AppData, обязательность CompanyName/ProductName в Runner.rc). Общий вывод («защита на уровне учётной записи ОС») сохранён, теперь с источником | https://github.com/juliansteenbakker/flutter_secure_storage/blob/develop/flutter_secure_storage_windows/windows/flutter_secure_storage_windows_plugin.cpp |
| 7 | minor | §15 pubspec (`custom_lint: any`, `drift_dev: any`); §1.1, §1.8, §2.3, §12 | `drift_dev: any` → `drift_dev: ^2.35.1` (последняя 2.35.1 от 2026-09-30, допускает `drift >=2.30.0 <2.36.0`). **Замечание по custom_lint исправлено иначе, чем предложено:** README и pubspec riverpod_lint 3.1.9 показывают, что пакет реализован на `analysis_server_plugin` и подключается через `analysis_options.yaml` (`plugins: riverpod_lint: ^3.1.9`); зависимости от custom_lint/custom_lint_builder в 3.1.9 нет (последняя версия с такой зависимостью — 3.0.3, `custom_lint_builder ^0.8.0`). Поэтому строка `custom_lint` из pubspec удалена (с пояснением), а упоминания «+ custom_lint» в §1.8, §2.3, §12 скорректированы. Справочно: последняя custom_lint на pub.dev — 0.8.1 (2025-09-09) | https://pub.dev/api/packages/drift_dev ; https://pub.dev/packages/riverpod_lint ; https://pub.dev/api/packages/riverpod_lint ; https://pub.dev/api/packages/custom_lint |
| 8 | minor | §10, первый абзац | Опечатка «[ПДТВЕРЖДЕНО: pub.dev]» → «[ПОДТВЕРЖДЕНО: https://pub.dev/packages/phone_numbers_parser]» | — |
| 9 | minor | Преамбула; §1.1–§1.8, колонка «Дата» | Для всех пакетов со статусом ВКЛЮЧИТЬ (и опциональных lottie, camera, google_mlkit_face_detection) относительные даты заменены на точные даты последнего релиза (UTC) из pub.dev API; у отклонённых/отложенных пакетов оставлены относительные значения. Примечание в преамбуле и описание столбцов §1 обновлены. Дополнительно в строке drift_dev проставлена версия 2.35.1 вместо «—» | https://pub.dev/api/packages/<name> для каждого пакета |

Не изменялось (замечаний не было, но затронуто косвенно): §2.2 (относительные даты в сравнительной таблице оставлены, т.к. это иллюстрация активности, а не справочные данные для ТЗ); §8 (версии freezed 4.0.3 / json_serializable 6.14.1 верны).
