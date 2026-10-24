// Версии клиента: `X-App-Version` (`1.4.2+87`), `X-Min-App-Version` /
// `X-Recommended-App-Version` (`android=1.2.0,windows=1.2.0`) — 08 §2.3, §2.11; D-46.

/// Семантическая версия сборки. Метаданные сборки (`+87`) при сравнении не учитываются;
/// пре-релиз (`-rc.1`) младше релиза той же версии.
final class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.preRelease = ''});

  /// `null` — строка не является версией.
  static AppVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2) ?? '0'),
      int.parse(match.group(3) ?? '0'),
      preRelease: match.group(4) ?? '',
    );
  }

  /// Разбор значения `platform=semver[,platform=semver…]`. Значение без `platform=`
  /// применяется ко всем платформам (ключ `*`). Некорректные пары пропускаются.
  static Map<String, AppVersion> parseByPlatform(String header) {
    final result = <String, AppVersion>{};
    for (final part in header.split(',')) {
      final pair = part.split('=');
      final platform = pair.length == 2 ? pair.first.trim().toLowerCase() : '*';
      final version = tryParse(pair.last);
      if (pair.length > 2 || platform.isEmpty || version == null) continue;
      result[platform] = version;
    }
    return result;
  }

  /// Версия для [platform] из заголовка (или общая `*`).
  static AppVersion? forPlatform(String? header, String? platform) {
    if (header == null || header.trim().isEmpty) return null;
    final map = parseByPlatform(header);
    return map[platform] ?? map['*'];
  }

  final int major;
  final int minor;
  final int patch;
  final String preRelease;

  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    return preRelease.compareTo(other.preRelease);
  }

  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() => '$major.$minor.$patch${preRelease.isEmpty ? '' : '-$preRelease'}';
}

final RegExp _pattern = RegExp(r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');
