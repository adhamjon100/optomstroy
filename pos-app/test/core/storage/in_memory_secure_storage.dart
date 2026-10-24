// In-memory SecureStorage для тестов.
import 'package:optomstroy/core/storage/secure_storage.dart';

final class InMemorySecureStorage implements SecureStorage {
  InMemorySecureStorage([Map<SecureKey, String> initial = const {}]) : values = Map.of(initial);

  final Map<SecureKey, String> values;

  @override
  Future<String?> read(SecureKey key) async => values[key];

  @override
  Future<void> write(SecureKey key, String value) async => values[key] = value;

  @override
  Future<void> delete(SecureKey key) async => values.remove(key);
}
