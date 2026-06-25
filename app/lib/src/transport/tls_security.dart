import 'dart:io';

class TlsConfigException implements Exception {
  final String message;
  const TlsConfigException(this.message);
  @override
  String toString() => 'TlsConfigException: $message';
}

/// Returns the [HttpClient.badCertificateCallback] to install for the given
/// [insecure] flag: a permissive (always-accept) callback when insecure is on,
/// or `null` when off so server verification stays enforced. Factored out
/// because [HttpClient.badCertificateCallback] is write-only and thus cannot be
/// asserted on a built client.
bool Function(X509Certificate, String, int)? insecureBadCertificateCallback(
  bool insecure,
) =>
    insecure ? (cert, host, port) => true : null;

/// Builds an [HttpClient] for mutual-TLS to a Docker daemon. The client cert +
/// key authenticate us; [caPem], when given, pins the server to that CA.
/// [insecure] skips server verification (off by default).
HttpClient buildTlsHttpClient({
  required List<int> clientCertPem,
  required List<int> clientKeyPem,
  List<int>? caPem,
  bool insecure = false,
  String? keyPassword,
}) {
  final SecurityContext ctx;
  try {
    ctx = SecurityContext(withTrustedRoots: false);
    ctx.useCertificateChainBytes(clientCertPem);
    ctx.usePrivateKeyBytes(clientKeyPem, password: keyPassword);
    if (caPem != null) ctx.setTrustedCertificatesBytes(caPem);
  } on TlsException catch (e) {
    throw TlsConfigException(e.message);
  } on ArgumentError catch (e) {
    throw TlsConfigException(e.toString());
  }
  final client = HttpClient(context: ctx);
  final badCertCallback = insecureBadCertificateCallback(insecure);
  if (badCertCallback != null) {
    client.badCertificateCallback = badCertCallback;
  }
  return client;
}
