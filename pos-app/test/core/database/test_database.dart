// Общая настройка SQLite для unit-тестов drift.
//
// В `flutter test` на Windows бандл `sqlite3_flutter_libs` не подключается
// (он входит только в сборку приложения), а `package:sqlite3` 2.x ищет
// `sqlite3.dll`. Используется системная `winsqlite3.dll` (Windows 10+).
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

bool _configured = false;

void configureSqliteForTests() {
  if (_configured) return;
  _configured = true;
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, () {
      try {
        return DynamicLibrary.open('sqlite3.dll');
      } on ArgumentError {
        return DynamicLibrary.open('winsqlite3.dll');
      }
    });
  }
}
