import 'package:optomstroy/core/network/backend_health.dart';

/// Фейковая проверка `GET /health` для widget-тестов (без сети).
final class FakeBackendHealthProbe implements BackendHealthProbe {
  FakeBackendHealthProbe({this.ok = true});

  final bool ok;
  int calls = 0;

  @override
  Future<BackendHealthReport> check() async {
    calls++;
    return BackendHealthReport(ok: ok, httpStatus: ok ? 200 : 503);
  }

  @override
  void close() {}
}
