// Хранение настроек HID-сканера на устройстве: drift `settings` (07 §11.2), ключ
// `scanner.wedge`, scope `device` — переживает выход пользователя (очищается только scope `user`).
// Серверная настройка `Settings.scanner.suffix` (`PUT /me/settings`, 08 §3.14) — на экране SCR-42;
// здесь — её локальная копия и порог между символами (EQ-SCAN-01).
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';

/// Порт хранения настроек сканера.
abstract interface class ScannerSettingsStore {
  /// Сохранённые настройки или настройки по умолчанию.
  Future<ScannerWedgeConfig> load();

  /// Сохраняет настройки.
  Future<void> save(ScannerWedgeConfig config);
}

/// Хранение в памяти (до входа, когда локальной БД нет, и в тестах).
final class MemoryScannerSettingsStore implements ScannerSettingsStore {
  /// Создаёт хранилище с начальным значением [initial].
  MemoryScannerSettingsStore([this._value = const ScannerWedgeConfig()]);

  ScannerWedgeConfig _value;

  @override
  Future<ScannerWedgeConfig> load() async => _value;

  @override
  Future<void> save(ScannerWedgeConfig config) async => _value = config;
}

/// Хранение в drift `settings` (scope `device`).
final class DriftScannerSettingsStore implements ScannerSettingsStore {
  /// Создаёт хранилище над [db]; [nowMs] — часы для `updated_at`.
  DriftScannerSettingsStore(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Ключ строки `settings`.
  static const String key = 'scanner.wedge';

  final AppDatabase _db;
  final int Function() _nowMs;

  @override
  Future<ScannerWedgeConfig> load() async {
    final row = await (_db.select(_db.localSettings)..where((t) => t.key.equals(key))).getSingleOrNull();
    return ScannerWedgeConfig.decode(row?.valueJson);
  }

  @override
  Future<void> save(ScannerWedgeConfig config) => _db
      .into(_db.localSettings)
      .insertOnConflictUpdate(
        LocalSettingsCompanion.insert(
          key: key,
          valueJson: jsonEncode(config.toJson()),
          scope: 'device',
          updatedAt: _nowMs(),
          dirty: const Value(false),
        ),
      );
}
