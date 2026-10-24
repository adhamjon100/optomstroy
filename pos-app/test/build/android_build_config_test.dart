// T-BIO-018 (09 BIO-027), T-SESS-022 (static, SEC-085), ревью D-MN-08: статические требования сборки Android —
// FlutterFragmentActivity (BiometricPrompt), USE_BIOMETRIC, allowBackup=false, правила извлечения данных
// Android 12+ (облачная копия и перенос device-to-device исключены), канал криптопривязки D-13.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  const String manifest = 'android/app/src/main/AndroidManifest.xml';

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
