// T-BIO-018 (09 BIO-027), T-SESS-022 (static, SEC-085), ревью D-MN-08: статические требования сборки Android —
// FlutterFragmentActivity (BiometricPrompt), USE_BIOMETRIC, allowBackup=false, правила извлечения данных
// Android 12+ (облачная копия и перенос device-to-device исключены), канал криптопривязки D-13.
// T-BIO-027 (12 §3.24; 09 BIO-003, BIO-027, BIO-030; 15 ADR-116 п. 2): натив Android дорожкой LF не меняется —
// уровень W входа по лицу целиком на Dart (`local_auth`, `flutter_secure_storage`), путь S (канал ADR-087) прежний.
// Gradle и `kotlinc` тест не запускает.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Коммит до дорожки LF «Вход по лицу» (12 T-BIO-027; 13 §3.14).
const String _lfBase = '37d92e0';

/// `git` только для чтения (`--no-optional-locks`: индекс не обновляется); `null` — git или база недоступны.
String? _git(List<String> args) {
  try {
    final ProcessResult r = Process.runSync('git', <String>['--no-optional-locks', ...args]);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}

void main() {
  const String manifest = 'android/app/src/main/AndroidManifest.xml';

  test('T-BIO-027 (1): git diff --stat 37d92e0 -- pos-app/android пуст; новых файлов в android нет', () {
    if (_git(<String>['cat-file', '-e', '$_lfBase^{commit}']) == null) {
      markTestSkipped('нет git или коммита $_lfBase (неполная копия репозитория) — проверка (2) ниже выполняется');
      return;
    }
    expect(_git(<String>['diff', '--stat', _lfBase, '--', 'android']), isEmpty);
    expect(_git(<String>['ls-files', '--others', '--exclude-standard', '--', 'android']), isEmpty);
  });

  test('T-BIO-027 (2): путь S не изменён — алиас v1, AUTH_BIOMETRIC_STRONG, инвалидация, CryptoObject, '
      'secureScreen, FlutterFragmentActivity', () {
    final List<File> kotlin = Directory(
      'android/app/src/main/kotlin',
    ).listSync(recursive: true).whereType<File>().toList();
    final String kt = kotlin.firstWhere((File f) => f.path.endsWith('BiometricCryptoChannel.kt')).readAsStringSync();
    expect(kt, contains('kg.optomstroy/biometric_crypto'));
    expect(kt, contains('"optomstroy.biometric_refresh.v1"'), reason: 'алиас ключа протокола v1');
    expect(kt, contains('setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)'));
    expect(kt, contains('setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)'));
    expect(kt, contains('setInvalidatedByBiometricEnrollment(true)'));
    expect(kt, contains('BiometricPrompt.CryptoObject(cipher)'));
    expect(kt, contains('"secureScreen"'));
    expect(kt, isNot(contains('BIOMETRIC_WEAK')), reason: 'уровень W — через local_auth, не через канал');
    final String activity = kotlin.firstWhere((File f) => f.path.endsWith('MainActivity.kt')).readAsStringSync();
    expect(activity, contains(': FlutterFragmentActivity()'), reason: 'BiometricPrompt local_auth (уровень W)');
  });

  test('T-BIO-018: MainActivity — FlutterFragmentActivity; USE_BIOMETRIC; канал kg.optomstroy/biometric_crypto', () {
    final String m = _read(manifest);
    expect(m, contains('android.permission.USE_BIOMETRIC'));
    final File activity = Directory(
      'android/app/src/main/kotlin',
    ).listSync(recursive: true).whereType<File>().firstWhere((File f) => f.path.endsWith('MainActivity.kt'));
    expect(activity.readAsStringSync(), contains(': FlutterFragmentActivity()'));
    final File channel = Directory(
      'android/app/src/main/kotlin',
    ).listSync(recursive: true).whereType<File>().firstWhere((File f) => f.path.endsWith('BiometricCryptoChannel.kt'));
    final String kt = channel.readAsStringSync();
    expect(kt, contains('kg.optomstroy/biometric_crypto'));
    expect(kt, contains('setUserAuthenticationRequired(true)'));
    expect(kt, contains('setInvalidatedByBiometricEnrollment(true)'));
    expect(kt, contains('BiometricPrompt.CryptoObject'));
  });

  test(
    'T-SESS-022 / D-MN-08: allowBackup=false, fullBackupContent=false, dataExtractionRules исключают все домены',
    () {
      final String m = _read(manifest);
      expect(m, contains('android:allowBackup="false"'));
      expect(m, contains('android:fullBackupContent="false"'));
      expect(m, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
      final String rules = _read('android/app/src/main/res/xml/data_extraction_rules.xml');
      for (final String section in <String>['cloud-backup', 'device-transfer']) {
        final RegExpMatch? block = RegExp(
          '<$section>'
          r'([\s\S]*?)'
          '</$section>',
        ).firstMatch(rules);
        expect(block, isNotNull, reason: section);
        for (final String domain in <String>['root', 'file', 'database', 'sharedpref', 'external']) {
          expect(block!.group(1), contains('<exclude domain="$domain" path="." />'), reason: '$section/$domain');
        }
        expect(block!.group(1), isNot(contains('<include')), reason: section);
      }
    },
  );

  test('T-SESS-022: secure storage — iOS first_unlock_this_device; токены не в SharedPreferences', () {
    final String storage = _read('lib/core/storage/secure_storage.dart');
    expect(storage, contains('KeychainAccessibility.first_unlock_this_device'));
    expect(storage, contains('FlutterSecureStorage'));
  });
}
