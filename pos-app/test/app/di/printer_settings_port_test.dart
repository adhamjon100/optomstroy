// Секция «Принтер» SCR-42 в корне (02 UI-42-014, UI-42-020…022, AC-UI-42-010; PRINT-006/009/010; ревью G-trace-4):
// формат и автопечать — `/me/settings` (запрос только при их изменении), адрес и порт ESC/POS — устройство, тестовая
// печать 80 мм — образец ESC/POS «ТЕСТОВАЯ ПЕЧАТЬ · не является фискальным документом» (CP866, шкала 48 символов)
// по TCP; ошибка соединения — причина, без блокировки; A4 — системная печать PDF-образца.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/printer_settings_port.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart' show OrderDocumentFile;
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';
import 'package:optomstroy/features/settings/presentation/widgets/printer_section.dart';

const String _title = 'ТЕСТОВАЯ ПЕЧАТЬ · не является фискальным документом';

final class _Repo implements LoginProtectionRepository {
  LoginProtectionState state = const LoginProtectionState(
    userKind: UserKind.staff,
    pinSet: true,
    biometricsEnabled: false,
    support: BiometricSupport.windowsHelloGate,
    platformLabel: BiometricPlatformLabel.windows,
    printerFormat: '80mm',
    printerAutoPrint: true,
  );
  final List<Map<String, Object?>> patches = <Map<String, Object?>>[];

  @override
  Future<Result<LoginProtectionState>> load() async => Success<LoginProtectionState>(state);

  @override
  Future<Result<Map<String, Object?>>> patchSettings(Map<String, Object?> patch) async {
    patches.add(patch);
    return Success<Map<String, Object?>>(patch);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

bool _contains(List<int> hay, List<int> needle) {
  for (int i = 0; i + needle.length <= hay.length; i++) {
    bool ok = true;
    for (int j = 0; j < needle.length && ok; j++) {
      ok = hay[i + j] == needle[j];
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  late _Repo repo;
  late List<({String host, int port, List<int> bytes})> sent;
  late List<OrderDocumentFile> printed;
  String? sendResult;

  AppPrinterSettingsPort port({bool system = true}) {
    final AppPrinterSettingsPort p = AppPrinterSettingsPort(
      settings: repo,
      dao: null,
      send: (String host, int port, List<int> bytes) async {
        sent.add((host: host, port: port, bytes: bytes));
        return sendResult;
      },
      systemPrint: system
          ? (OrderDocumentFile f) async {
              printed.add(f);
              return true;
            }
          : null,
      a4Sample: (PrinterTestTexts t, String stamp, String device) async => <int>[0x25, 0x50, 0x44, 0x46],
      stamp: () => '22.10.2026 10:30',
      device: 'POS-01',
      nowMs: () => 0,
    );
    p.texts = const PrinterTestTexts(title: _title, noAddress: 'нет адреса', notSent: 'Отмена');
    return p;
  }

  setUp(() {
    repo = _Repo();
    sent = <({String host, int port, List<int> bytes})>[];
    printed = <OrderDocumentFile>[];
    sendResult = null;
  });

  test('CP866: кириллица, Ё/ё, точка-разделитель; ASCII без изменений', () {
    expect(encodeCp866('АПРЯапря'), <int>[0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xAF, 0xE0, 0xEF]);
    expect(encodeCp866('Ёё·A1'), <int>[0xF0, 0xF1, 0xFA, 0x41, 0x31]);
  });

  test('образец ESC/POS: ESC @, ESC t 17, заголовок, дата, устройство, шкала 48 символов, отрезка', () {
    final List<int> b = escPosTestPage(title: _title, stamp: '22.10.2026 10:30', device: 'POS-01');
    expect(b.take(5).toList(), <int>[0x1B, 0x40, 0x1B, 0x74, 0x11]);
    expect(_contains(b, encodeCp866('не является фискальным документом')), isTrue);
    expect(_contains(b, '22.10.2026 10:30'.codeUnits), isTrue);
    expect(_contains(b, 'POS-01'.codeUnits), isTrue);
    expect(_contains(b, <int>[...'123456789012345678901234567890123456789012345678'.codeUnits, 0x0A]), isTrue);
    expect(b.sublist(b.length - 4), <int>[0x1D, 0x56, 0x42, 0x00]);
  });

  test('load: формат и автопечать с сервера; save: PUT /me/settings только при изменении формата/автопечати', () async {
    final AppPrinterSettingsPort p = port();
    final PrinterPrefs prefs = await p.load();
    expect(prefs.format, PrinterFormat.receipt80);
    expect(prefs.autoPrint, isTrue);
    expect(await p.save(prefs.copyWith(address: '192.168.1.50', port: 9100)), isTrue);
    expect(repo.patches, isEmpty, reason: 'адрес и порт — только устройство');
    expect(await p.save(prefs.copyWith(format: PrinterFormat.a4)), isTrue);
    expect(repo.patches.single, <String, Object?>{
      'printer': <String, Object?>{'defaultFormat': 'a4', 'autoPrint': true},
    });
    final PrinterPrefs again = await port().load();
    expect(again.address, isNull, reason: 'новый порт без БД — память своего экземпляра');
  });

  test(
    '80 мм: без адреса — причина; с адресом — ESC/POS на host:9100; ошибка соединения — причина (AC-UI-42-010)',
    () async {
      final AppPrinterSettingsPort p = port();
      expect(await p.testPrint(const PrinterPrefs(format: PrinterFormat.receipt80)), 'нет адреса');
      expect(sent, isEmpty);
      expect(await p.testPrint(const PrinterPrefs(format: PrinterFormat.receipt80, address: '192.168.1.50')), isNull);
      expect(sent.single.host, '192.168.1.50');
      expect(sent.single.port, kEscPosDefaultPort);
      expect(_contains(sent.single.bytes, encodeCp866(_title)), isTrue);
      sendResult = '192.168.1.50:9100 — 10 s';
      expect(
        await p.testPrint(const PrinterPrefs(format: PrinterFormat.receipt80, address: '192.168.1.50', port: 9101)),
        '192.168.1.50:9100 — 10 s',
      );
      expect(sent.last.port, 9101);
    },
  );

  test('A4: системная печать PDF-образца; без принтера — причина', () async {
    expect(await port().testPrint(const PrinterPrefs(format: PrinterFormat.a4)), isNull);
    expect(printed.single.fileName, 'test-page.pdf');
    expect(printed.single.bytes, <int>[0x25, 0x50, 0x44, 0x46]);
    expect(await port(system: false).testPrint(const PrinterPrefs(format: PrinterFormat.a4)), 'Отмена');
  });

  test('sendEscPosTcp: байты доходят до принтера; закрытый порт — причина с адресом', () async {
    final ServerSocket server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final Completer<List<int>> got = Completer<List<int>>();
    server.listen((Socket s) async {
      final List<int> all = <int>[];
      await for (final List<int> chunk in s) {
        all.addAll(chunk);
      }
      if (!got.isCompleted) got.complete(all);
    });
    final List<int> bytes = escPosTestPage(title: _title, stamp: 's', device: 'd');
    expect(await sendEscPosTcp('127.0.0.1', server.port, bytes), isNull);
    expect(await got.future.timeout(const Duration(seconds: 5)), bytes);

    final ServerSocket closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int free = closed.port;
    await closed.close();
    final String? reason = await sendEscPosTcp('127.0.0.1', free, bytes, timeout: const Duration(seconds: 2));
    expect(reason, startsWith('127.0.0.1:$free — '));
  });
}
