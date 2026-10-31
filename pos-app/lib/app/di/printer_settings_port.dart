// Секция «Принтер» SCR-42 в приложении (02 UI-42-014, UI-42-020…UI-42-022; PRINT-006, PRINT-009, PRINT-010; D-27,
// Q-019; ревью G-trace-4): реализация [PrinterSettingsPort] корня (settings не импортирует печать — DAG 06 §6.1).
//
// * Формат по умолчанию и автопечать — серверные настройки пользователя: чтение из `/me` (`Settings.printer`), запись
//   `PUT /me/settings {printer: {defaultFormat, autoPrint}}` (`LoginProtectionRepository.patchSettings`).
// * Адрес и порт сетевого ESC/POS — только устройство: drift `settings(scope=device)` (`printer.address`,
//   `printer.port`); без БД (до входа) — память.
// * Тестовая печать: «Чек 80 мм» — образец ESC/POS «ТЕСТОВАЯ ПЕЧАТЬ · не является фискальным документом» с датой,
//   именем устройства и шкалой ширины 48 символов по TCP (порт по умолчанию 9100, таймаут 10 с); A4 — системный диалог
//   печати с PDF-образцом, сформированным локально. Ошибка — причина для `settings_print_error`, экран не блокируется.
// * В браузере (веб-демо, ADR-113) сырого TCP нет: «Чек 80 мм» отвечает причиной «Недоступно на этом устройстве», без
//   обращения к dart:io (`Socket`, `Platform` там бросают UnsupportedError); A4 — системный диалог печати браузера.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:optomstroy/core/database/daos/settings_dao.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart' show OrderDocumentFile;
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';
import 'package:optomstroy/features/settings/presentation/widgets/printer_section.dart';

/// Отправка байтов на сетевой ESC/POS-принтер; `null` — отправлено, иначе причина ошибки.
typedef EscPosSend = Future<String?> Function(String host, int port, List<int> bytes);

/// Системная печать PDF (`OrderDocumentPrinter.print`); `true` — отправлено.
typedef SystemPdfPrint = Future<bool> Function(OrderDocumentFile file);

/// Порт ESC/POS по умолчанию (RAW 9100).
const int kEscPosDefaultPort = 9100;

/// Таймаут соединения и отправки (02 UI-42-014).
const Duration kEscPosTimeout = Duration(seconds: 10);

/// ESC/POS по TCP доступна в сборке (в браузере сырого TCP нет).
bool escPosTcpSupported({bool isWeb = kIsWeb}) => !isWeb;

/// TCP-отправка ESC/POS (02 UI-42-014: «нет связи / таймаут 10 с»). В браузере не вызывается: там «Чек 80 мм» отвечает
/// причиной [PrinterTestTexts.unsupported] раньше (`escPosSupported` в [AppPrinterSettingsPort]); прочие ошибки
/// платформы пробрасываются, как до веб-демо.
Future<String?> sendEscPosTcp(String host, int port, List<int> bytes, {Duration timeout = kEscPosTimeout}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: timeout);
    socket.add(bytes);
    await socket.flush().timeout(timeout);
    return null;
  } on SocketException catch (e) {
    return '$host:$port — ${e.osError?.message ?? e.message}';
  } on TimeoutException {
    return '$host:$port — ${timeout.inSeconds} s';
  } finally {
    socket?.destroy();
  }
}

/// Имя устройства на тестовой странице (имя компьютера; иначе — ОС). В браузере `Platform` из dart:io недоступен.
String printerDeviceName({bool isWeb = kIsWeb}) {
  if (isWeb) return 'Браузер';
  try {
    return Platform.localHostname;
  } on Object {
    return Platform.operatingSystem;
  }
}

/// Кириллица и ASCII → кодовая страница PC866 (ESC t 17); прочие символы — `?`.
List<int> encodeCp866(String text) => <int>[
  for (final int c in text.runes)
    if (c < 0x80)
      c
    else if (c >= 0x0410 && c <= 0x043F)
      0x80 +
          (c - 0x0410) // А…п
    else if (c >= 0x0440 && c <= 0x044F)
      0xE0 +
          (c - 0x0440) // р…я
    else if (c == 0x0401)
      0xF0 // Ё
    else if (c == 0x0451)
      0xF1 // ё
    else if (c == 0x00B7)
      0xFA // ·
    else if (c == 0x2014 || c == 0x2013)
      0x2D // — –
    else
      0x3F,
];

/// Образец 80 мм ESC/POS (PRINT-010): заголовок, дата (Бишкек), устройство, шкала ширины 48 символов, отрезка.
List<int> escPosTestPage({required String title, required String stamp, required String device}) {
  const List<int> init = <int>[0x1B, 0x40]; // ESC @
  const List<int> cp866 = <int>[0x1B, 0x74, 0x11]; // ESC t 17
  const List<int> center = <int>[0x1B, 0x61, 0x01];
  const List<int> left = <int>[0x1B, 0x61, 0x00];
  const List<int> boldOn = <int>[0x1B, 0x45, 0x01];
  const List<int> boldOff = <int>[0x1B, 0x45, 0x00];
  const List<int> feed = <int>[0x1B, 0x64, 0x04]; // ESC d 4
  const List<int> cut = <int>[0x1D, 0x56, 0x42, 0x00]; // GS V 66 0
  final String scale = List<String>.generate(48, (int i) => '${(i + 1) % 10}').join();
  List<int> line(String s) => <int>[...encodeCp866(s), 0x0A];
  return <int>[
    ...init,
    ...cp866,
    ...center,
    ...boldOn,
    ...line(title),
    ...boldOff,
    ...left,
    ...line(stamp),
    ...line(device),
    ...line(scale),
    ...feed,
    ...cut,
  ];
}

/// Тексты образца и причин (локализует построитель секции).
final class PrinterTestTexts {
  const PrinterTestTexts({
    required this.title,
    required this.noAddress,
    required this.notSent,
    required this.unsupported,
  });

  /// `settings_print_test_page_title`.
  final String title;

  /// Нет адреса сетевого ESC/POS (`settings_printer_address_error`).
  final String noAddress;

  /// Системная печать не выполнена (диалог закрыт).
  final String notSent;

  /// Формат недоступен на этом устройстве — ESC/POS в браузере (`reg_bio_unsupported` «Недоступно на этом устройстве»).
  final String unsupported;
}

/// [PrinterSettingsPort] корня.
final class AppPrinterSettingsPort implements PrinterSettingsPort {
  AppPrinterSettingsPort({
    required LoginProtectionRepository settings,
    required SettingsDao? dao,
    required EscPosSend send,
    required SystemPdfPrint? systemPrint,
    required Future<List<int>> Function(PrinterTestTexts texts, String stamp, String device) a4Sample,
    required String Function() stamp,
    required String device,
    required int Function() nowMs,
    bool? escPosSupported,
  }) : _settings = settings,
       _dao = dao,
       _send = send,
       _systemPrint = systemPrint,
       _a4Sample = a4Sample,
       _stamp = stamp,
       _device = device,
       _nowMs = nowMs,
       _escPosSupported = escPosSupported ?? escPosTcpSupported();

  static const String addressKey = 'printer.address';
  static const String portKey = 'printer.port';

  final LoginProtectionRepository _settings;
  final SettingsDao? _dao;
  final EscPosSend _send;
  final SystemPdfPrint? _systemPrint;
  final Future<List<int>> Function(PrinterTestTexts texts, String stamp, String device) _a4Sample;
  final String Function() _stamp;
  final String _device;
  final int Function() _nowMs;

  /// Сетевой ESC/POS доступен ([escPosTcpSupported]); иначе «Чек 80 мм» — причина [PrinterTestTexts.unsupported].
  final bool _escPosSupported;

  /// Тексты текущей локали (подставляет построитель секции).
  PrinterTestTexts texts = const PrinterTestTexts(title: '', noAddress: '', notSent: '', unsupported: '');

  /// Последние значения сервера (запрос `PUT /me/settings` — только при их изменении).
  PrinterFormat? _serverFormat;
  bool _serverAutoPrint = false;

  /// Адрес и порт без БД (до входа) — память.
  String? _memAddress;
  int? _memPort;

  @override
  Future<PrinterPrefs> load() async {
    final Result<LoginProtectionState> r = await _settings.load();
    final LoginProtectionState state = switch (r) {
      Success<LoginProtectionState>(:final value) => value,
      FailureResult<LoginProtectionState>(:final failure) => throw StateError('printer settings: $failure'),
    };
    _serverFormat = PrinterFormat.tryParse(state.printerFormat);
    _serverAutoPrint = state.printerAutoPrint ?? false;
    String? address = _memAddress;
    int? port = _memPort;
    final SettingsDao? dao = _dao;
    if (dao != null) {
      address = _decode(await dao.read(addressKey)) as String? ?? address;
      final Object? storedPort = _decode(await dao.read(portKey));
      if (storedPort is int) port = storedPort;
    }
    return PrinterPrefs(format: _serverFormat, autoPrint: _serverAutoPrint, address: address, port: port);
  }

  static Object? _decode(String? json) {
    if (json == null) return null;
    try {
      return jsonDecode(json);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<bool> save(PrinterPrefs prefs) async {
    if (prefs.format != _serverFormat || prefs.autoPrint != _serverAutoPrint) {
      final Result<Map<String, Object?>> r = await _settings.patchSettings(<String, Object?>{
        'printer': <String, Object?>{'defaultFormat': ?prefs.format?.value, 'autoPrint': prefs.autoPrint},
      });
      if (r is FailureResult<Map<String, Object?>>) return false;
      _serverFormat = prefs.format;
      _serverAutoPrint = prefs.autoPrint;
    }
    final String? address = (prefs.address ?? '').trim().isEmpty ? null : prefs.address!.trim();
    _memAddress = address;
    _memPort = prefs.port;
    final SettingsDao? dao = _dao;
    if (dao == null) return true;
    try {
      final int now = _nowMs();
      if (address == null) {
        await dao.remove(addressKey);
      } else {
        await dao.write(addressKey, jsonEncode(address), scope: SettingScope.device, nowMs: now);
      }
      if (prefs.port == null) {
        await dao.remove(portKey);
      } else {
        await dao.write(portKey, jsonEncode(prefs.port), scope: SettingScope.device, nowMs: now);
      }
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<String?> testPrint(PrinterPrefs prefs) async {
    final String stamp = _stamp();
    if (prefs.format == PrinterFormat.a4) {
      final SystemPdfPrint? print = _systemPrint;
      if (print == null) return texts.notSent;
      try {
        final List<int> bytes = await _a4Sample(texts, stamp, _device);
        final bool sent = await print(OrderDocumentFile(bytes: bytes, fileName: 'test-page.pdf'));
        return sent ? null : texts.notSent;
      } on Object catch (e) {
        return e.runtimeType.toString();
      }
    }
    if (!_escPosSupported) return texts.unsupported;
    final String host = (prefs.address ?? '').trim();
    if (host.isEmpty) return texts.noAddress;
    return _send(
      host,
      prefs.port ?? kEscPosDefaultPort,
      escPosTestPage(title: texts.title, stamp: stamp, device: _device),
    );
  }
}
