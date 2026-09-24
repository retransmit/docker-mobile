class TlsCredentials {
  final String host;
  final int port;
  final String clientCertPem;
  final String clientKeyPem;
  final String? caPem;
  final bool insecure;

  const TlsCredentials({
    required this.host,
    required this.port,
    required this.clientCertPem,
    required this.clientKeyPem,
    this.caPem,
    this.insecure = false,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'clientCertPem': clientCertPem,
        'clientKeyPem': clientKeyPem,
        'caPem': caPem,
        'insecure': insecure,
      };

  factory TlsCredentials.fromJson(Map<String, dynamic> json) => TlsCredentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        clientCertPem: json['clientCertPem'] as String,
        clientKeyPem: json['clientKeyPem'] as String,
        caPem: json['caPem'] as String?,
        insecure: json['insecure'] as bool? ?? false,
      );
}

class AgentCredentials {
  final String baseUri;
  final String token;
  const AgentCredentials({required this.baseUri, required this.token});
  Map<String, dynamic> toJson() => {'baseUri': baseUri, 'token': token};
  factory AgentCredentials.fromJson(Map<String, dynamic> json) =>
      AgentCredentials(baseUri: json['baseUri'] as String, token: json['token'] as String? ?? '');
}

enum SshAuthMethod { password, key }

class SshCredentials {
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
  final String? pinnedHostKey;

  const SshCredentials({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.password,
    this.privateKeyPem,
    this.passphrase,
    this.pinnedHostKey,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'password': password,
        'privateKeyPem': privateKeyPem,
        'passphrase': passphrase,
        'pinnedHostKey': pinnedHostKey,
      };

  factory SshCredentials.fromJson(Map<String, dynamic> json) => SshCredentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        username: json['username'] as String,
        authMethod: SshAuthMethod.values.byName(json['authMethod'] as String),
        password: json['password'] as String?,
        privateKeyPem: json['privateKeyPem'] as String?,
        passphrase: json['passphrase'] as String?,
        pinnedHostKey: json['pinnedHostKey'] as String?,
      );
}
