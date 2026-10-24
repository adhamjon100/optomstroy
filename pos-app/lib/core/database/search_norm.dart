// Нормализация строк поиска на клиенте — повтор серверных `norm_search` и `norm_sku`
// (pos-api/migrations/0001_init.sql; 07 §11.3, DATA-261; ядро D-31):
//
//   norm_search(t) = trim(regexp_replace(unaccent(replace(lower(t), 'ё', 'е')), '[[:space:][:punct:]]+', ' ', 'g'))
//   norm_sku(t)    = upper(regexp_replace(t, '[[:space:]\-_./]+', '', 'g'))
//
// `unaccent` воспроизводится таблицей замен для латиницы с диакритикой и кириллицы
// (`й` → `и`, `ё` → `е`, как в стандартном `unaccent.rules` PostgreSQL); буквы
// кыргызского алфавита `ң`, `ө`, `ү` разложения не имеют и не меняются.
// Чистый Dart: используется DAO каталога (core/database) и мапперами слоя data.

/// Нормализация поисковых строк (локальный поиск по `name_norm` / `sku_norm`).
abstract final class SearchNorm {
  /// `norm_search`: нижний регистр, `ё` → `е`, снятие диакритики, пробелы и пунктуация → один пробел.
  static String text(String input) {
    final lower = input.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(_unaccent[ch] ?? ch);
    }
    return buffer.toString().replaceAll(_separators, ' ').trim();
  }

  /// `norm_sku`: верхний регистр без пробелов, `-`, `_`, `.`, `/`.
  static String sku(String input) => input.toUpperCase().replaceAll(_skuSeparators, '');

  /// Слова нормализованного запроса (для поиска «все слова входят в `name_norm`»).
  static List<String> tokens(String input) {
    final normalized = text(input);
    if (normalized.isEmpty) return const <String>[];
    return normalized.split(' ');
  }

  /// Экранирование `%`, `_` и `\` для `LIKE … ESCAPE '\'`.
  static String escapeLike(String value) => value.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
}

/// `[[:space:][:punct:]]+` — пробельные символы, пунктуация и символы (POSIX `punct` в ASCII
/// включает и знаки `$+<=>^`|~`, в Unicode им соответствуют категории P и S).
final RegExp _separators = RegExp(r'[\s\p{P}\p{S}]+', unicode: true);

final RegExp _skuSeparators = RegExp(r'[\s\-_./]+');

/// Замены `unaccent` (строчные буквы — вход уже в нижнем регистре).
const Map<String, String> _unaccent = <String, String>{
  'ё': 'е',
  'й': 'и',
  'ї': 'і',
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'æ': 'ae',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ğ': 'g',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'œ': 'oe',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ß': 'ss',
  'ť': 't',
  'ţ': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
};
