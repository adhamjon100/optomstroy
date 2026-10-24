import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/network/backend_health.dart';

void main() {
  test('адрес /health строится от origin API_BASE_URL (вне префикса /api/v1)', () {
    Uri health(String base) => DioBackendHealthProbe.healthUriFor(Uri.parse(base));

    expect(health('http://127.0.0.1:3000/api/v1').toString(), 'http://127.0.0.1:3000/health');
    expect(health('https://pos.example.kg/api/v1').toString(), 'https://pos.example.kg/health');
    expect(health('https://localhost:8443/api/v1/').toString(), 'https://localhost:8443/health');
  });

  test('недоступный backend → ok=false без исключения', () async {
    // Порт 9 (discard) на loopback закрыт: соединение отклоняется сразу.
    final config = AppConfig.fromMap(const {'API_BASE_URL': 'http://127.0.0.1:9/api/v1', 'ENV': 'staging'});
    final probe = DioBackendHealthProbe(config, timeout: const Duration(seconds: 2));
    addTearDown(probe.close);

    final report = await probe.check();

    expect(report.ok, isFalse);
    expect(report.httpStatus, anyOf(isNull, isNot(200)));
  });
}
