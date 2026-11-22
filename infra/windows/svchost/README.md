# OptomstroySvc — хост служб Windows

`OptomstroySvc.exe` запускает программу Optomstroy POS (API, фоновые задачи, резервное копирование) как службу Windows. Это наша программа: исходник `OptomstroySvc.cs` (C# 5, .NET Framework 4.x), без сторонних библиотек и без WinSW/NSSM. Собирается встроенным компилятором `csc.exe`, который есть в каждой Windows Server 2022.

Одна копия `OptomstroySvc.exe` обслуживает все три службы. Каждая служба получает свой файл настроек `*.svc.json`.

| Файл | Назначение |
|---|---|
| `OptomstroySvc.cs` | исходник хоста |
| `build-svchost.ps1` | сборка и печать SHA256 |
| `rehearse-service.ps1` | репетиция режима службы на настоящем SCM для администратора (временная служба, затем удаляется); `-DevTest` — то же без SCM и без прав администратора |
| `test-fixtures\child.mjs`, `test-fixtures\SendCtrlC.cs` | тестовый дочерний процесс и отправка Ctrl+C для `infra\windows\tests\svchost.tests.ps1` |

## Что делает хост

1. Читает и проверяет `*.svc.json`: неизвестные ключи, пропущенные ключи, типы, полные пути, наличие `executable` и `workingDirectory`. Обо всех ошибках сообщает сразу, с номером строки для ошибок JSON.
2. Создаёт объект задания Windows (Job Object) с `KILL_ON_JOB_CLOSE`. Запускает программу без окна, приостановленной, помещает её в задание и только потом даёт ей работать. Поэтому все её потомки тоже оказываются в задании и не переживут хост, даже если хост будет убит. Если заданы `jobMemoryLimitMB` и `cpuRatePercent`, задание ограничивает память и процессор всего дерева процессов (замена `mem_limit`/`cpus` из Linux-комплекта, чтобы node.exe не вытеснил 1С и SQL Server).
   Окружение программы: при `"inheritEnvironment": false` передаются только системные переменные (`SystemRoot`, `windir`, `PATH`, `TEMP`, `TMP`, `USERPROFILE`, `ProgramData`, `COMPUTERNAME` и подобные, полный список — `BaseEnvironment` в исходнике) и ключ `environment`. При `true` (по умолчанию, для совместимости) передаётся всё окружение Windows.
3. Перенаправляет stdout и stderr в журналы `<name>.out.log` и `<name>.err.log` байт-в-байт. Вывод `node.exe` в UTF-8 не перекодируется. События самого хоста (запуск, остановка, коды выхода, ошибки) пишутся в `<name>.svc.log`.
4. stdin программы — канал, который хост держит открытым до остановки.
5. **Остановка** (служба остановлена, выключается Windows или нажат Ctrl+C в режиме `--console`):
   - при `shutdownViaStdin: true` хост закрывает stdin. Программа видит конец stdin и выполняет обычную штатную остановку: для pos-api нужна переменная `POS_SHUTDOWN_ON_STDIN_EOF=1`. Хост ждёт до `stopTimeoutSeconds`;
   - если программа не завершилась за это время, или сразу при `shutdownViaStdin: false`, хост завершает всё дерево процессов через задание;
   - если после штатного выхода программы в задании остались её потомки, хост завершает и их и пишет об этом в журнал;
   - пока идёт остановка, хост сообщает диспетчеру служб (SCM) `SERVICE_STOP_PENDING` с подсказкой времени ожидания, чтобы SCM не счёл службу зависшей.
6. **Неожиданный выход программы** (остановку никто не запрашивал): запись в журнал хоста и в журнал событий, затем хост завершается с кодом 4 без отчёта `SERVICE_STOPPED`. SCM считает это сбоем службы и выполняет действия восстановления, то есть перезапуск (см. ниже).

## Командная строка

```
OptomstroySvc.exe --config <путь\к\файлу.svc.json>             режим службы (запускает только SCM)
OptomstroySvc.exe --console --config <путь\к\файлу.svc.json>   в окне; Ctrl+C — штатная остановка, второй Ctrl+C — немедленно
OptomstroySvc.exe --check-config --config <путь\к\файлу.svc.json>
OptomstroySvc.exe --version
OptomstroySvc.exe --service-test <stop|shutdown|preshutdown> --config <путь>   только для тестов: класс службы без SCM
```

Если запустить режим службы вручную, без SCM и без `--console`, хост сразу выходит с кодом 2 и подсказкой.

`--console` и режим службы используют одно ядро (запуск, журналы, неожиданный выход, остановка). Класс службы — тонкая обёртка над ним. `--service-test` вызывает те же методы класса службы (`OnStart`, `OnStop`, `OnShutdown`, PRESHUTDOWN) без SCM. Ctrl+C означает выбранную команду остановки.

Коды выхода:

| Код | Значение |
|---|---|
| 0 | штатная остановка: программа завершилась сама с кодом 0, или `shutdownViaStdin: false` и дерево процессов завершено |
| 1 | внутренняя ошибка хоста |
| 2 | ошибка аргументов или файла настроек |
| 3 | не удалось запустить программу (например, `executable` — не исполняемый файл) |
| 4 | программа завершилась сама, без запроса остановки |
| 5 | программа не завершилась за `stopTimeoutSeconds` (или нажат второй Ctrl+C) и завершена принудительно |
| 6 | при остановке программа завершилась сама, но с ненулевым кодом |

В режиме службы коды 0, 5 и 6 видны только в `<name>.svc.log`: службу остановили по запросу, и SCM получает «остановлена». Код 4 означает для SCM сбой. Если служба не смогла запуститься (ошибка файла настроек, папка журналов недоступна, программа не запускается), SCM получает `WIN32_EXIT_CODE 1067`. Это видно в `sc.exe query`, и при `sc.exe failureflag 1` применяются действия восстановления. Причина записывается один раз в журнал событий Application (источник `OptomstroySvc`) и, если журнал открылся, в `<name>.svc.log`.

## Файл настроек `*.svc.json`

Файл в кодировке UTF-8, с BOM или без него. Ключи чувствительны к регистру. Ключи, которые начинаются с `_` (например `_comment`), считаются комментариями. В строках JSON обратная косая черта удваивается: `"D:\\Optomstroy"`. Значений секретов в файле нет: секреты передаются через переменные `*_FILE` в `config\*.env`.

| Ключ | Тип | Обязателен | Описание |
|---|---|---|---|
| `name` | строка | да | Имя для журналов: `A–Z a–z 0–9 . _ -`, до 80 символов. Совпадает с именем службы |
| `executable` | строка | да | Полный путь к программе, файл должен существовать |
| `arguments` | массив строк | да | Аргументы, можно пустой `[]`. Кавычки и пробелы экранируются хостом по правилам Windows |
| `workingDirectory` | строка | да | Полный путь к рабочей папке, папка должна существовать |
| `environment` | объект | нет | `{"ИМЯ": "значение"}` добавляется к окружению службы. Значение `null` удаляет унаследованную переменную. В журнал попадают только имена переменных |
| `logDirectory` | строка | да | Полный путь к папке журналов, создаётся при необходимости |
| `logMaxBytes` | целое | да | Размер файла журнала до ротации, от 1024 до 1073741824 |
| `logKeepFiles` | целое | да | Сколько старых файлов хранить, от 1 до 100 |
| `stopTimeoutSeconds` | целое | да | Сколько ждать штатной остановки после закрытия stdin, от 1 до 3600 |
| `shutdownViaStdin` | true/false | да | Останавливать закрытием stdin. Для pos-api — `true` вместе с `POS_SHUTDOWN_ON_STDIN_EOF=1` |
| `inheritEnvironment` | true/false | нет | По умолчанию `true`: программа получает всё окружение Windows. `false` — только системные переменные и `environment`. **Для служб Optomstroy — `false`** (см. ниже) |
| `jobMemoryLimitMB` | целое | нет | Лимит выделенной памяти на всё дерево процессов, от 64 до 1048576 МБ. Программа, которая упёрлась в лимит, падает. Хост выходит с кодом 4 и пишет в журнал пик памяти с пометкой «вероятно, достигнут лимит памяти», а SCM перезапускает службу |
| `cpuRatePercent` | целое | нет | Жёсткий потолок процессора для дерева процессов, от 1 до 100 **процентов всей машины** (всех логических процессоров), а не одного ядра |

**Почему `inheritEnvironment: false` и почему важные переменные задаются в `environment`.** `node --env-file` не заменяет переменную, которая уже есть в окружении процесса. Если на сервере 1С задана общесистемная переменная с тем же именем (`API_HOST`, `DATABASE_URL`, `NODE_OPTIONS`, `NODE_TLS_REJECT_UNAUTHORIZED`, `HTTP(S)_PROXY` и т. п.), она молча перекроет значение из `config\api.env`. В Docker-комплекте такого нет: контейнер стартует с чистым окружением. Поэтому:
- в `*.svc.json` служб Optomstroy задаётся `"inheritEnvironment": false`;
- переменные, от которых зависит безопасность и остановка (`API_HOST`, `API_PORT`, `POS_SHUTDOWN_ON_STDIN_EOF`, `APP_ENV`), задаются в ключе `environment`. Хост применяет его последним, и он ничем не перекрывается;
- хост читает файлы из аргументов `--env-file=` / `--env-file-if-exists=` и пишет предупреждение в `<name>.svc.log` (и в журнал событий), если унаследованная переменная Windows совпадает по имени с переменной из файла. При `inheritEnvironment: true` он также предупреждает об унаследованных `NODE_*` и `*_PROXY`. В журнал попадают только имена, без значений.

**Лимиты, как в Linux-комплекте** (`infra/compose.prod.yml`): API — 1 ГБ и 1,5 процессора, фоновые задачи — 1 ГБ и 1,0, резервное копирование — 512 МБ и 0,5. В Windows лимит процессора задаётся долей всей машины: `cpuRatePercent = округлить(процессоры × 100 / число логических процессоров)`. Пример для 8 логических процессоров: API — 19, фоновые задачи — 13, резервное копирование — 6. Число процессоров сервера администратор смотрит командой `(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors`. Чтобы V8 завершался понятной ошибкой «heap out of memory» раньше лимита задания, в `arguments` добавляется `--max-old-space-size` примерно на 75 % лимита: 768 для 1 ГБ. Для резервного копирования лимит задания включает и дочерний `pg_dump`, поэтому там 256.

Пример для API (`D:\Optomstroy\config\api.svc.json`):

```json
{
  "_comment": "Optomstroy POS API: служба OptomstroyApi",
  "name": "OptomstroyApi",
  "executable": "D:\\Optomstroy\\current\\node\\node.exe",
  "arguments": ["--max-old-space-size=768", "--env-file=D:\\Optomstroy\\config\\api.env", "dist\\main.js"],
  "workingDirectory": "D:\\Optomstroy\\current\\api",
  "inheritEnvironment": false,
  "environment": {
    "APP_ENV": "prod",
    "API_HOST": "127.0.0.1",
    "API_PORT": "3000",
    "POS_SHUTDOWN_ON_STDIN_EOF": "1"
  },
  "jobMemoryLimitMB": 1024,
  "cpuRatePercent": 19,
  "logDirectory": "D:\\Optomstroy\\logs\\api",
  "logMaxBytes": 20971520,
  "logKeepFiles": 10,
  "stopTimeoutSeconds": 30,
  "shutdownViaStdin": true
}
```

Для тестового контура (`api-test.<домен>`) — `"APP_ENV": "staging"`, своё имя службы, порт и папки. Для фоновых задач (`worker.svc.json`) отличаются `name` (`OptomstroyWorker`), файл `worker.env`, скрипт `dist\\worker.js`, папка `logs\\worker`, `cpuRatePercent` (13 для 8 процессоров). В `environment` остаются `APP_ENV` и `POS_SHUTDOWN_ON_STDIN_EOF`, без `API_HOST`/`API_PORT`. Остальные переменные (адрес базы через `*_FILE` и т. п.) задаются в `config\*.env`. Настройки службы `OptomstroyBackup` (программа и аргументы) задаёт комплект резервного копирования (`infra\windows\backup`). Формат файла тот же. Для него рекомендуются `"inheritEnvironment": false`, `"jobMemoryLimitMB": 512` и `"cpuRatePercent"` по формуле выше.

`POS_SHUTDOWN_ON_STDIN_EOF=1` нельзя задавать при запуске API или фоновых задач без хоста: если stdin закрыт или не подключён, программа остановится сразу после запуска.

## Журналы

- `<logDirectory>\<name>.out.log` — stdout программы, `<name>.err.log` — stderr, `<name>.svc.log` — события хоста (время, уровень, текст).
- Ротация по размеру: `<name>.out.log` → `<name>.out.1.log` → … → `<name>.out.<logKeepFiles>.log`, самый старый удаляется. Ротация выполняется только на границе строки, поэтому файл может превысить `logMaxBytes` на одну строку. Исключение — строка без перевода строки длиннее `logMaxBytes`: тогда файл ротируется посреди неё, когда достигнет `2 × logMaxBytes`.
- При перезапуске журналы дописываются, а не затираются.
- Файлы открыты на запись с разрешением чтения для других программ, поэтому `Get-Content -Wait` работает во время работы службы. Если ротации мешает программа, которая держит файл открытым без разрешения удаления, хост продолжает писать в текущий файл, пишет предупреждение в `<name>.svc.log` и повторяет ротацию через 30 секунд. Если старый файл уже переименован, а новый не открывается (антивирус, программа резервного копирования, права NTFS), вывод временно теряется. Хост повторяет открытие не чаще раза в 5 секунд и каждый раз пишет предупреждение. Когда файл снова открыт, в журнал записывается число потерянных байт. Служба при этом продолжает работать.
- Предупреждения и ошибки хоста дублируются в журнал Windows «Приложение» (Application), источник `OptomstroySvc`. Запись работает и без регистрации источника, но тогда «Просмотр событий» показывает текст с пометкой «описание не найдено». Чтобы пометки не было, администратор один раз регистрирует источник (команда ниже).

## Сборка

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\svchost\build-svchost.ps1 -OutDir <папка релиза>\svchost
```

Без `-OutDir` файл попадает в `<репозиторий>\.tmp\wn-svchost\bin`: папка `.tmp` исключена из git, поэтому собранный `.exe` нельзя случайно закоммитить. Вне рабочей копии git файл попадает в `bin` рядом со скриптом.

Скрипт печатает путь, версию, компилятор и SHA256. Встроенный `csc.exe` не умеет детерминированную сборку (`/deterministic`): он записывает в файл время сборки и случайные GUID. Скрипт заменяет эти поля значениями, вычисленными из SHA256 исходника, параметров сборки и строки версии компилятора. Повторная сборка того же исходника на **том же** `csc.exe` даёт побайтно одинаковый файл. Это проверено только на одном ПК разработчика (Windows 11, `csc.exe` 4.8.9221.0, NET481REL1LAST_25H2). На другой машине результат не проверялся.

SHA256 из заметок к релизу относится только к той сборке компилятора, которая указана там же в строке «Компилятор». На Windows Server 2022 стоит другая сборка `csc.exe`, и SHA256 почти наверняка будет другим. Поэтому администратор:
- сверяет SHA256 присланного `OptomstroySvc.exe` с заметками к релизу (файл не изменён в пути);
- если хочет собрать сам, собирает из исходника релиза и сравнивает строку «Компилятор» с заметками. Если строки совпадают, должен совпасть и SHA256. Если различаются, разница SHA256 ожидаема, и тогда сверяется SHA256 исходника `OptomstroySvc.cs`.

## Команды для администратора сервера

Этот раздел только для администратора. `posdeploy` эти команды выполнить не может. Команды проверены разбором и чтением, но на сервере не выполнялись: у нас нет прав администратора, а регистрация служб требует этих прав. Пути даны для корня `D:\Optomstroy`. Шаги создания папок, выдачи прав NTFS и прав `posdeploy` на управление службами описаны в общем порядке установки `infra\windows\README.md`. Здесь приведено только то, что относится к хосту.

Учётные записи служб — виртуальные учётные записи Windows `NT SERVICE\OptomstroyApi`, `NT SERVICE\OptomstroyWorker`, `NT SERVICE\OptomstroyBackup`. Пароли не нужны и не хранятся. Каждая такая учётная запись появляется вместе со службой, поэтому права NTFS для неё выдаются **после** `sc.exe create`.

### 0. Репетиция режима службы (однократно, до регистрации рабочих служб)

Режим службы на настоящем SCM нами не проверялся: у `posdeploy` и у нас нет прав администратора. Поэтому до шага 3 администратор один раз запускает репетицию. Она создаёт временную службу `OptomstroySvcRehearsal` под `NT SERVICE\OptomstroySvcRehearsal` со своей копией `node.exe` в `%ProgramData%\OptomstroySvcRehearsal` и проверяет:
- запуск;
- учётную запись процесса;
- штатную остановку (`WIN32_EXIT_CODE 0`);
- перезапуск SCM после `Stop-Process` дочернего `node.exe` (события 7031/7034);
- ошибку настроек (`WIN32_EXIT_CODE 1067`, одна запись в Application).

В конце скрипт удаляет службу и папку. Рабочие службы, Apache, порты 80/443 и Hyper-V он не затрагивает.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Optomstroy\current\svchost\rehearse-service.ps1 -Node D:\Optomstroy\current\node\node.exe
# Итог: «Итог репетиции: N проверок, ошибок: 0», код выхода 0. При ошибках — прислать вывод и папку журналов (-KeepWorkDir)
```

PRESHUTDOWN и порядок остановки (службы Optomstroy раньше `OptomstroyPostgres`) проверяются только настоящим выключением. Поэтому **обязательная приёмка перед запуском в работу**: после регистрации служб (шаг 3) и выдачи прав — одна плановая перезагрузка сервера в согласованное окно, затем:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File D:\Optomstroy\current\svchost\rehearse-service.ps1 -CheckAfterReboot -InstallRoot D:\Optomstroy
# Итог: «Итог приёмки выключения: 10 проверок, ошибок: 0», код выхода 0
```

Скрипт ничего не меняет, только читает журналы. Для `OptomstroyApi`, `OptomstroyWorker`, `OptomstroyBackup` он ищет в `logs\<служба>\<имя>.svc*.log` последнюю до загрузки строку «выключение Windows (PRESHUTDOWN)» и следующую за ней «остановлено (Graceful)». Затем сверяет время с записью PostgreSQL «database system is shut down» в `logs\pg` (другая папка — `-PgLogDir`). Если вместо PRESHUTDOWN пришёл SHUTDOWN, остановка не Graceful или служба остановилась позже PostgreSQL — запуск в работу откладывается, вывод и журналы присылаются нам.

### 1. Сверка и регистрация источника журнала событий (однократно)

```powershell
Get-FileHash D:\Optomstroy\current\svchost\OptomstroySvc.exe -Algorithm SHA256   # сравнить с SHA256 из релиза
D:\Optomstroy\current\svchost\OptomstroySvc.exe --version
New-EventLog -LogName Application -Source OptomstroySvc   # если источник уже есть — ошибка «already registered», это нормально
```

### 2. Проверка файлов настроек

```powershell
foreach ($n in 'api','worker','backup') {
  D:\Optomstroy\current\svchost\OptomstroySvc.exe --check-config --config "D:\Optomstroy\config\$n.svc.json"
  if ($LASTEXITCODE -ne 0) { throw "Ошибка в $n.svc.json" }
}
```

### 3. Регистрация служб

В Windows PowerShell 5.1 кавычки внутри аргумента для `sc.exe` записываются как `\"`. После `binPath=`, `start=`, `obj=` и других ключей обязателен пробел.

```powershell
$svcExe = 'D:\Optomstroy\current\svchost\OptomstroySvc.exe'
$defs = @(
  @{ Name = 'OptomstroyApi';    Display = 'Optomstroy POS API';           Cfg = 'D:\Optomstroy\config\api.svc.json';    Depend = 'OptomstroyPostgres' },
  @{ Name = 'OptomstroyWorker'; Display = 'Optomstroy POS фоновые задачи'; Cfg = 'D:\Optomstroy\config\worker.svc.json'; Depend = 'OptomstroyPostgres' },
  @{ Name = 'OptomstroyBackup'; Display = 'Optomstroy POS резервные копии'; Cfg = 'D:\Optomstroy\config\backup.svc.json'; Depend = 'OptomstroyPostgres' }
)
foreach ($d in $defs) {
  $bin = '\"' + $svcExe + '\" --config \"' + $d.Cfg + '\"'
  sc.exe create $d.Name binPath= $bin start= delayed-auto obj= "NT SERVICE\$($d.Name)" DisplayName= $d.Display depend= $d.Depend
  if ($LASTEXITCODE -ne 0) { throw "sc create $($d.Name): код $LASTEXITCODE" }
  sc.exe description $d.Name 'Optomstroy POS. Хост OptomstroySvc.exe, настройки в D:\Optomstroy\config'
  sc.exe sidtype $d.Name unrestricted
  # Восстановление: перезапуск через 10 с, 10 с, затем через 60 с; счётчик сбоев сбрасывается через сутки
  sc.exe failure $d.Name reset= 86400 actions= restart/10000/restart/10000/restart/60000
  # Действия восстановления и при остановке с ошибкой (не только при аварийном завершении процесса)
  sc.exe failureflag $d.Name 1
  # Сколько SCM ждёт остановку по PRESHUTDOWN при выключении Windows (мс). Задаётся в реестре службы,
  # у sc.exe нет отдельной команды для этого параметра. 90 с покрывают stopTimeoutSeconds (до 60 с) и запас.
  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($d.Name)" -Name PreshutdownTimeout -Value 90000 -Type DWord
}
sc.exe qc OptomstroyApi   # BINARY_PATH_NAME: "D:\Optomstroy\current\svchost\OptomstroySvc.exe" --config "D:\Optomstroy\config\api.svc.json"
```

Права NTFS для `NT SERVICE\Optomstroy*` выдаются после этого шага, по общему порядку установки. Хосту нужно:
- чтение и выполнение: `releases` (через `current`), `config` и файлы `secrets`, которые нужны этой службе;
- изменение: своя папка журналов `logs\<служба>` (хост сам создаёт её, если её нет и есть право на `logs`).

Пример для API:

```powershell
icacls D:\Optomstroy\logs\api /grant 'NT SERVICE\OptomstroyApi:(OI)(CI)M'
```

Если администратор раньше запускал хост сам (`--console`), файлы журналов в `logs\<служба>` могли быть созданы от его имени. Тогда служба не сможет их дописывать: она не запустится, `sc.exe query` покажет `WIN32_EXIT_CODE 1067`, а в журнале Application появится «не удалось открыть журнал хоста». Права на уже созданные файлы выдаются той же командой `icacls` с ключом `/T`.

### 4. Право «Вход в качестве службы»

Виртуальные учётные записи получают его через группу `NT SERVICE\ALL SERVICES` (SID `S-1-5-80-0`), которая по умолчанию входит в право `SeServiceLogonRight`. Если групповая политика домена переопределяет это право, служба не запустится с ошибкой 1069. Проверка, только чтение:

```powershell
secedit /export /areas USER_RIGHTS /cfg $env:TEMP\ur.inf | Out-Null
Select-String -Path $env:TEMP\ur.inf -Pattern '^SeServiceLogonRight'   # в строке должен быть *S-1-5-80-0
Remove-Item $env:TEMP\ur.inf
```

### 5. Запуск и проверка

```powershell
Start-Service OptomstroyApi, OptomstroyWorker
Get-Service Optomstroy* | Select-Object Name, Status, StartType
Get-Content D:\Optomstroy\logs\api\OptomstroyApi.svc.log -Tail 20
Get-NetTCPConnection -State Listen -LocalPort 3000 | Select-Object LocalAddress, OwningProcess   # только 127.0.0.1
```

Проверка штатной остановки: `Stop-Service OptomstroyApi`. В `OptomstroyApi.svc.log` должны появиться строки «stdin дочернего процесса закрыт», «завершился с кодом 0» и «остановлено (Graceful)», а в `OptomstroyApi.out.log` — строка `api.shutdown: stdin-eof`.

Проверка перезапуска после сбоя: найти PID `node.exe` в `OptomstroyApi.svc.log` («процесс запущен, PID …») и выполнить `Stop-Process -Id <PID> -Force`. В журнале хоста появится «неожиданно завершился», в журнале событий System — событие 7031 или 7034 от Service Control Manager, а через 10 секунд служба снова будет в состоянии Running.

### 6. Удаление (откат)

```powershell
foreach ($n in 'OptomstroyBackup','OptomstroyWorker','OptomstroyApi') {
  if (Get-Service $n -ErrorAction SilentlyContinue) {
    Stop-Service $n -ErrorAction SilentlyContinue
    sc.exe delete $n
  }
}
# Remove-EventLog -Source OptomstroySvc   # только если источник больше не нужен
```

## Ограничения

- **Выключение Windows.** При обычном `SERVICE_CONTROL_SHUTDOWN` SCM рассылает команду всем службам сразу, без учёта зависимостей, и ждёт не дольше `WaitToKillServiceTimeout`. На ПК разработчика этот параметр равен 5000 мс. Тогда `OptomstroyPostgres` может остановиться раньше, чем API и фоновые задачи закончат работу. Поэтому хост принимает **PRESHUTDOWN**. Свойства для него в `ServiceBase` .NET Framework нет, поэтому хост добавляет `SERVICE_ACCEPT_PRESHUTDOWN` в закрытое поле `acceptedCommands`; это поле есть в .NET Framework 4.8 (проверено отражением). Команду 0x0F хост обрабатывает в `OnCustomCommand` и вызывает `ServiceBase.Stop()`. Тогда SCM останавливает службы Optomstroy в порядке зависимостей раньше `OptomstroyPostgres` и ждёт до `PreshutdownTimeout` (шаг 3, 90 с). Если поле в будущей версии .NET не найдётся, хост пишет предупреждение «PRESHUTDOWN недоступен» и работает через SHUTDOWN, как раньше. Задание с `KILL_ON_JOB_CLOSE` в любом случае завершит процессы вместе с хостом. Путь команды в .NET Framework 4.8.1 (`System.ServiceProcess` 4.8.9221.0) проверен разбором IL через отражение: `ServiceCommandCallback` передаёт неизвестную команду в `DeferredCustomCommand` последним действием, без `SetServiceStatus` после него; `DeferredCustomCommand` вызывает только `OnCustomCommand` и `WriteEventLogEntry`. Состояние SERVICE_STOPPED сообщает только `ServiceBase.Stop()` → `DeferredStop`, повторного отчёта после него нет. **Не проверено на настоящем SCM:** обработчик проверен вызовом через `--service-test preshutdown`, а сама рассылка PRESHUTDOWN и порядок остановки проверяются только перезагрузкой — обязательная приёмка `-CheckAfterReboot` (шаг 0). Время остановки фоновых задач с живой базой (`runtime.stop()` pg-boss, `pool.end()`) мы не измеряли. Остановка API без базы заняла около 1 с.
- Хост не перезапускает программу сам: перезапуск выполняет SCM по действиям восстановления (шаг 3). Это сделано, чтобы у сбоев был один источник правды — журнал событий System.
- **Режим службы на настоящем SCM не проверялся**: регистрация служб, виртуальные учётные записи, действия восстановления, коды 1067/7031/7034 и журнал событий с зарегистрированным источником. Для этого нужны права администратора, проверка выполняется скриптом `rehearse-service.ps1` (шаг 0). Тестами проверены: весь режим `--console` и класс службы через `--service-test`. Это тот же код `OnStart`/`OnStop`/`OnShutdown`/PRESHUTDOWN и потока наблюдения, но без SCM, поэтому `RequestAdditionalTime` и `SetServiceStatus` в них ничего не делают.
- `--max-old-space-size` и `jobMemoryLimitMB` проверены на тестовом процессе: при 256 МБ `node.exe` упал с `RangeError: Array buffer allocation failed`, хост вышел с кодом 4. Под настоящей нагрузкой pos-api лимиты не проверялись.

## Тесты

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\svchost.tests.ps1            # 79 проверок
powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\tests\svchost.tests.ps1 -RealApi   # + 5: настоящий pos-api\dist\main.js на 127.0.0.1:3311 (inheritEnvironment=false, лимит 1 ГБ)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File infra\windows\svchost\rehearse-service.ps1 -DevTest -SvcExe <папка>\OptomstroySvc.exe -WorkDir .tmp\wn-svchost\rehearsal   # 5 проверок без SCM
```

Права администратора не нужны. Нужен `node.exe` в `PATH` (или параметр `-Node`). Временные файлы создаются в `.tmp\wn-svchost\test` и удаляются после прогона, параметр `-Keep` их оставляет. Что проверяется — в заголовке скрипта.
