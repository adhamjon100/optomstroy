// Кэш ETag-ответов (08 §2.8): только память процесса, ограниченный размер; ПДн не
// кэшируются — допускаются лишь пути из [EtagCache.cacheablePrefixes]
// (каталог и публичные настройки; `/me*`, `/orders*`, `/payments*` — `no-store`).
import 'dart:collection';

final class EtagEntry {
  const EtagEntry({required this.etag, required this.data});

  final String etag;
  final Object? data;
}

final class EtagCache {
  EtagCache({this.maxEntries = 200});

  /// Пути (относительно `/api/v1`), для которых используется `If-None-Match`.
  static const List<String> cacheablePrefixes = ['/catalog/', '/settings/public'];

  final int maxEntries;
  final LinkedHashMap<String, EtagEntry> _entries = LinkedHashMap<String, EtagEntry>();

  /// Путь подходит для кэширования.
  static bool isCacheablePath(String path) => cacheablePrefixes.any(path.contains);

  EtagEntry? get(String key) {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry; // LRU: обновить позицию
    return entry;
  }

  void put(String key, EtagEntry entry) {
    _entries.remove(key);
    _entries[key] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String key) => _entries.remove(key);

  /// Очистка при выходе / смене пользователя (цены зависят от роли).
  void clear() => _entries.clear();

  int get length => _entries.length;
}
