// Удаление файла локальной БД пользователя на Android и Windows (07 §11.1 п. 2; исключение из 11 SEC-133 — планшет
// магазина, ADR-115; 02 SCR-54.9; FLOW-043.S6): `pos_<user_id>.db` и журналы SQLite рядом с ним (`-wal`, `-shm`,
// `-journal`) в каталоге поддержки приложения (`getApplicationSupportDirectory`, как у `AppDatabase.openUserDatabase`).
// Вызывать только после закрытия БД. В браузере (веб-демо, ADR-113) — user_database_files_web.dart (условный импорт в
// app_database.dart).
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Файлы SQLite одной БД: сам файл и журналы.
const List<String> userDatabaseFileSuffixes = <String>['', '-wal', '-shm', '-journal'];

/// Удалить файлы БД [fileName]. `true` — файлов больше нет (удалены или их не было); [sqlite3Wasm] и [driftWorker]
/// нужны только в браузере.
Future<bool> deleteUserDatabaseFiles(String fileName, {required Uri sqlite3Wasm, required Uri driftWorker}) async {
  final String dir = (await getApplicationSupportDirectory()).path;
  bool removed = true;
  for (final String suffix in userDatabaseFileSuffixes) {
    final File file = File(p.join(dir, '$fileName$suffix'));
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      removed = false;
    }
  }
  return removed;
}
