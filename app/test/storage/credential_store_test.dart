import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';

void main() {
  test('TlsCredentials JSON round-trips all fields', () {
    const creds = TlsCredentials(
      host: '10.0.0.5', port: 2376,
      clientCertPem: 'CERT', clientKeyPem: 'KEY', caPem: 'CA', insecure: true,
    );
    final loaded = TlsCredentials.fromJson(creds.toJson());
    expect(loaded.host, '10.0.0.5');
    expect(loaded.port, 2376);
    expect(loaded.clientCertPem, 'CERT');
    expect(loaded.clientKeyPem, 'KEY');
    expect(loaded.caPem, 'CA');
    expect(loaded.insecure, true);
  });

  test('null CA and default insecure round-trip', () {
    const creds = TlsCredentials(host: 'h', port: 2376, clientCertPem: 'c', clientKeyPem: 'k');
    final loaded = TlsCredentials.fromJson(creds.toJson());
    expect(loaded.caPem, isNull);
    expect(loaded.insecure, false);
  });
}
