import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/timeouts.dart';
import 'package:docker_mobile/src/transport/tls_security.dart';

void main() {
  final cert = File('test/fixtures/client-cert.pem').readAsBytesSync();
  final key = File('test/fixtures/client-key.pem').readAsBytesSync();

  test('builds an HttpClient from valid client cert + key', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key);
    expect(client, isA<HttpClient>());
    client.close(force: true);
  });

  test('accepts a CA and keeps verification on by default', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key, caPem: cert);
    expect(client, isA<HttpClient>());
    // secure: no skip callback (badCertificateCallback is write-only on
    // HttpClient, so we assert the factored decision instead).
    expect(insecureBadCertificateCallback(false), isNull);
    client.close(force: true);
  });

  test('insecure:true installs a permissive badCertificateCallback', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key, insecure: true);
    expect(client, isA<HttpClient>());
    final callback = insecureBadCertificateCallback(true);
    expect(callback, isNotNull);
    expect(callback!(/*cert*/ _AnyCert(), 'host', 2376), isTrue);
    client.close(force: true);
  });

  test('malformed PEM throws TlsConfigException', () {
    expect(
      () => buildTlsHttpClient(clientCertPem: [1, 2, 3], clientKeyPem: [4, 5, 6]),
      throwsA(isA<TlsConfigException>()),
    );
  });

  test('buildTlsHttpClient applies the connect timeout', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key);
    expect(client.connectionTimeout, kConnectTimeout);
    final custom = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key, connectTimeout: const Duration(seconds: 3));
    expect(custom.connectionTimeout, const Duration(seconds: 3));
  });
}

class _AnyCert implements X509Certificate {
  @override
  noSuchMethod(Invocation invocation) => null;
}
