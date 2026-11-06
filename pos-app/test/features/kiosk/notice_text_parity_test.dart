// Текст информирования перед кодом на планшете магазина (02 ч. F SCR-52 UI-52-003, UI-52-004, AC-UI-52-002; 11 PRIV-032;
// 10 KIOSK-022; ADR-115 п. 16; 12 T-KIOSK-041; 13 TAB-2-04): строки ARB `kiosk_notice_short` / `kiosk_notice_full`,
// которые показывает приложение, совпадают с разделом `kiosk_order_notice` файла `contracts/legal/notices_ru.md`
// той версии, что уходит в `POST /kiosk/order-otp` (`kioskNoticeVersion`).
//
// Правила файла (`notices_ru.md`, «Правила»): короткий текст — первый абзац блока ```text дословно (с точкой в конце);
// полный — все абзацы, соединённые одним пробелом (ARB однострочный); `sha256` — SHA-256 байтов UTF-8 блока (LF, без
// начальных и конечных пустых строк). Сервер сверяет тот же файл (`pos-api/test/kiosk/notice-catalog.spec.ts`).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations_en.dart';
import 'package:optomstroy/core/l10n/app_localizations_ky.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';

/// Раздел `## kiosk_order_notice — версия <v>` файла: версия, заявленный хэш и блок текста.
({String version, String sha256, String block})? _section(String md, String version) {
  final RegExp head = RegExp(r'^## kiosk_order_notice — версия (\S+)$', multiLine: true);
  for (final RegExpMatch m in head.allMatches(md)) {
    if (m.group(1) != version) continue;
    final int next = md.indexOf(RegExp(r'^## ', multiLine: true), m.end);
    final String body = md.substring(m.end, next < 0 ? md.length : next);
    final String? sha = RegExp(r'^- sha256: `([0-9a-f]{64})`$', multiLine: true).firstMatch(body)?.group(1);
    final RegExpMatch? text = RegExp(r'```text\n([\s\S]*?)\n```').firstMatch(body);
    if (sha == null || text == null) return null;
    return (version: version, sha256: sha, block: text.group(1)!.replaceAll(RegExp(r'^\n+|\n+$'), ''));
  }
  return null;
}

Map<String, Object?> _arb(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

void main() {
  final String md = File('../contracts/legal/notices_ru.md').readAsStringSync().replaceAll('\r\n', '\n');
  final ({String version, String sha256, String block})? notice = _section(md, kioskNoticeVersion);

  test('T-KIOSK-041 версия приложения — раздел notices_ru.md; хэш блока совпадает с заявленным', () {
    expect(kioskNoticeVersion, '2026-11-04');
    expect(notice, isNotNull, reason: 'раздел kiosk_order_notice версии $kioskNoticeVersion');
    expect(sha256.convert(utf8.encode(notice!.block)).toString(), notice.sha256);
  });

  test('T-KIOSK-041 kiosk_notice_short — первый абзац дословно; kiosk_notice_full — все абзацы через пробел', () {
    final List<String> paragraphs = notice!.block.split('\n\n');
    expect(paragraphs.length, greaterThan(1));
    for (final String p in paragraphs) {
      expect(p, isNot(contains('\n')), reason: 'абзац — одна строка');
      expect(p.trim(), p);
    }
    final String short = paragraphs.first;
    final String full = paragraphs.join(' ');
    expect(short, endsWith('.'), reason: 'короткий текст — с точкой в конце (WP-D-CUST)');
    expect(full, contains('[ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-340]'));
    expect(full, contains('[ТРЕБУЕТ РЕШЕНИЯ ЗАКАЗЧИКА: Q-339]'));

    // То, что показывает приложение (сгенерированные строки ru; ky и en в R1 — без перевода).
    for (final (String locale, String shortText, String fullText) in <(String, String, String)>[
      ('ru', AppLocalizationsRu().kiosk_notice_short, AppLocalizationsRu().kiosk_notice_full),
      ('ky', AppLocalizationsKy().kiosk_notice_short, AppLocalizationsKy().kiosk_notice_full),
      ('en', AppLocalizationsEn().kiosk_notice_short, AppLocalizationsEn().kiosk_notice_full),
    ]) {
      expect(shortText, short, reason: 'kiosk_notice_short ($locale)');
      expect(fullText, full, reason: 'kiosk_notice_full ($locale)');
    }

    // Исходники ARB: контракт и вход gen-l10n.
    for (final String path in <String>[
      '../contracts/l10n/app_ru.arb',
      '../contracts/l10n/app_ky.arb',
      '../contracts/l10n/app_en.arb',
      'lib/l10n/gen_input/app_ru.arb',
      'lib/l10n/gen_input/app_ky.arb',
      'lib/l10n/gen_input/app_en.arb',
    ]) {
      final Map<String, Object?> arb = _arb(path);
      expect(arb['kiosk_notice_short'], short, reason: path);
      expect(arb['kiosk_notice_full'], full, reason: path);
    }
    // ICU-безопасно: в тексте нет плейсхолдеров и кавычек-экранов.
    expect(full, isNot(matches(RegExp("[{}']"))));
  });
}
