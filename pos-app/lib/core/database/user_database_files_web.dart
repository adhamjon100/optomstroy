// Удаление файла локальной БД пользователя в браузере (веб-демо, ADR-113; исключение из 11 SEC-133 — планшет
// магазина, ADR-115): БД drift wasm с именем `pos_<user_id>.db` в OPFS или IndexedDB — тем же воркером, что открывает
// её (`AppDatabase.webOptions`). Вызывать только после закрытия БД. На Android и Windows — user_database_files.dart.
import 'package:drift/wasm.dart';

/// Удалить БД [fileName] из хранилищ браузера. `true` — БД больше нет (удалена или её не было).
Future<bool> deleteUserDatabaseFiles(String fileName, {required Uri sqlite3Wasm, required Uri driftWorker}) async {
  final WasmProbeResult probe = await WasmDatabase.probe(
    sqlite3Uri: sqlite3Wasm,
    driftWorkerUri: driftWorker,
    databaseName: fileName,
  );
  bool removed = true;
  for (final ExistingDatabase db in probe.existingDatabases) {
    if (db.$2 != fileName) continue;
    try {
      await probe.deleteDatabase(db);
    } on Object {
      removed = false;
    }
  }
  return removed;
}
