import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/providers.dart';

import '../support/fake_transport.dart';

/// Reads [systemDashboardProvider] against [t] with a 5 s request budget and
/// returns a getter for the error it fails with (null while still pending).
Object? Function() _readDashboard(FakeTransport t) {
  final container = ProviderContainer(overrides: [
    dockerClientProvider.overrideWithValue(DockerApiClient(t, requestTimeout: const Duration(seconds: 5))),
  ]);
  addTearDown(container.dispose);
  Object? error;
  container.read(systemDashboardProvider.future).then((_) {}, onError: (Object e) { error = e; });
  return () => error;
}

void main() {
  test('a hung disk-usage call fails the dashboard at the long budget', () {
    fakeAsync((async) {
      final t = FakeTransport()
        ..onGet('/info', (_) => jsonResponse({'ServerVersion': '27.0.3'}))
        ..onGet('/version', (_) => jsonResponse({'Version': '27.0.3', 'ApiVersion': '1.46'}))
        ..hangOn('GET', '/system/df');
      final error = _readDashboard(t);
      async.elapse(const Duration(minutes: 9));
      expect(error(), isNull, reason: 'disk usage may legitimately run long');
      async.elapse(const Duration(minutes: 2));
      expect(error(), isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });

  test('the first failure surfaces without waiting on a slower call', () {
    fakeAsync((async) {
      final t = FakeTransport()
        ..hangOn('GET', '/info')
        ..onGet('/version', (_) => jsonResponse({'Version': '27.0.3', 'ApiVersion': '1.46'}))
        ..hangOn('GET', '/system/df');
      final error = _readDashboard(t);
      async.elapse(const Duration(seconds: 4));
      expect(error(), isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error(), isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout),
          reason: '/info hits its 5 s budget; the dashboard must not wait for /system/df');
    });
  });
}
