# lib/core — ядро клиента (RM-C-004)

Ядро не знает о фичах (L-4) и о design_system. Presentation обращается к нему только через
`core/di` (read-only провайдеры), `core/error`, `core/utils`, `core/l10n` (L-9).

| Каталог | Что внутри | Источник |
|---|---|---|
| `config/environment.dart` | `AppConfig`: `API_BASE_URL`, `ENV` (`ENVIRONMENT`), `LOG_LEVEL`, `FEATURE_FLAGS`, `FEATURE_FACE_SCAN`, `FEATURE_CUSTOMER_SELF_SERVICE` через `--dart-define(-from-file)` | 06 §6.9 |
| `enums.dart` | генерируется `scripts/gen_enums.py` из `contracts/enums.json` | RM-B-009 |
| `error/` | `Failure` (sealed), `Result`, `ScreenState` — чистый Dart | 06 §6.8, §6.11 |
| `network/` | `DioClient` + интерсепторы, `ErrorMapper`, `TokenStore`, `TokenRefresher`, `AppVersionController`, `EtagCache`, DTO `models/` | 06 §6.7, 08 §2 |
| `database/` | drift `AppDatabase` (ровно 07 §11.2), `AppMetaDao`, снимки схем и шаги миграций | 07 §11 |
| `storage/secure_storage.dart` | refresh-токен, `deviceId`, флаг биометрии, черновые ФИО/год рождения | 07 §11.1 п.4 |
| `connectivity/` | `ConnectivityWatcher` → `OnlineStatus` | 06 §6.7, §6.12 |
| `utils/` | `Money`/`Percent`/`MoneyMath` (тыйыны, HALF_UP), `Qty` (milli-units), `PhoneNumber` (+996), `Debouncer`, `Clock`, `AppVersion`, `PiiMasker` | 10 §18, R3 §10 |
| `di/core_providers.dart` | провайдеры ядра | 06 §6.10 |

Форматирование денег, количеств и дат для UI — только `design_system/formats` (03 §17.1);
в `core/utils` его нет (MV-25 проверяется там).

## Интерсепторы (порядок)

`RequestId → ClientMeta → AppVersion → OnlineStatus → Logging → ETag → Auth → Retry`.

- Auth: access только в памяти; 401 `UNAUTHENTICATED`/`TOKEN_STALE` → single-flight `/auth/refresh`
  и один повтор; `SESSION_REVOKED` → очистка токенов (кроме `deviceId`) и `SessionEvent.ended`;
  `UNLOCK_REQUIRED` → `SessionEvent.unlockRequired`; `PIN_INVALID`/`PIN_LOCKED` → без refresh.
- Retry (08 §2.10): GET/HEAD/PUT/DELETE, POST/PATCH только с `Idempotency-Key`; приём денег
  (`POST /orders/{id}/payments`, `/payments`, `/payments/{id}/confirm-manual|void`) автоматически
  не повторяется (ядро §22.6) — повтор только действием кассира тем же ключом.
- AppVersion (RM-C-015, клиент): `426` → `AppVersionStatus.updateRequired` (SCR-90),
  `X-Recommended-App-Version` выше текущей → `updateRecommended` (мягкий баннер);
  значения пишутся в `app_meta.min_app_version_seen` / `recommended_app_version_seen`.
- Logging: метод, путь, имена query-параметров, статус, код, requestId; тела и заголовки не пишутся.

## Подключение в bootstrap (задача FE / app)

```dart
final storage = FlutterSecureStorageAdapter();
final meta = await ClientMeta.load(storage);
ProviderScope(overrides: [
  clientMetaProvider.overrideWithValue(meta),
  // после входа: appDatabaseProvider.overrideWithValue(AppDatabase.forUser(userId)),
], child: const App());
```

## Команды (из `pos-app/`)

```
python -I -X utf8 ../scripts/gen_enums.py --out <tmp>  # затем <tmp>/enums.dart → lib/core/enums.dart
dart run build_runner build -d                          # drift, freezed, json_serializable
# после изменения схемы drift: поднять AppDatabase.latestSchemaVersion, добавить шаг в migration, затем
dart run drift_dev schema dump lib/core/database/app_database.dart lib/core/database/schemas/
dart run drift_dev schema steps lib/core/database/schemas/ lib/core/database/migrations/schema_versions.dart
dart run drift_dev schema generate --data-classes --companions lib/core/database/schemas/ test/core/database/generated/
flutter test test/core --coverage --branch-coverage
```

`drift_dev schema dump` исполняет код таблиц: значения в `.check(...)` должны быть публичными
(приватная константа ломает экспорт, дамп откатывается к статическому анализу).

Тесты БД в `flutter test` на Windows используют системную `winsqlite3.dll`
(`test/core/database/test_database.dart`); в сборке приложения SQLite берётся из
`sqlite3_flutter_libs`. Наличие FTS5 в бандле не проверено (нужна сборка, RM-C-013).
