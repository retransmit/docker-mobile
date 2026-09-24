/// The newest Engine API version this client is written against.
const String kClientApiVersion = '1.45';

/// Daemons below this still connect; the app warns once.
const String kMinSupportedApiVersion = '1.41';

/// "v1.45 " -> "1.45".
String normalizeApiVersion(String v) {
  final t = v.trim();
  return (t.startsWith('v') || t.startsWith('V')) ? t.substring(1) : t;
}

(int, int) _parts(String v) {
  final p = normalizeApiVersion(v).split('.');
  final major = int.tryParse(p.isNotEmpty ? p[0] : '') ?? 0;
  final minor = int.tryParse(p.length > 1 ? p[1] : '') ?? 0;
  return (major, minor);
}

/// Numeric "major.minor" comparison ("1.10" > "1.9"). Invalid parts count as 0.
int compareApiVersions(String a, String b) {
  final pa = _parts(a);
  final pb = _parts(b);
  final major = pa.$1.compareTo(pb.$1);
  return major != 0 ? major : pa.$2.compareTo(pb.$2);
}

/// The version to prefix requests with: the smaller of the daemon's and ours.
/// An unusable daemon value yields [client].
String negotiateApiVersion(String daemonApiVersion, {String client = kClientApiVersion}) {
  final d = _parts(daemonApiVersion);
  if (d.$1 == 0 && d.$2 == 0) return client;
  final daemon = '${d.$1}.${d.$2}';
  return compareApiVersions(daemon, client) < 0 ? daemon : client;
}

bool isBelowMinSupported(String daemonApiVersion) =>
    compareApiVersions(daemonApiVersion, kMinSupportedApiVersion) < 0;
