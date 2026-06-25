import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../transport/connection_config.dart';
import '../../transport/tls_security.dart';
import '../../transport/transport.dart';
import '../home_screen.dart';

class TlsForm extends ConsumerStatefulWidget {
  const TlsForm({super.key});
  @override
  ConsumerState<TlsForm> createState() => _TlsFormState();
}

class _TlsFormState extends ConsumerState<TlsForm> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '2376');
  final _cert = TextEditingController();
  final _key = TextEditingController();
  final _ca = TextEditingController();
  bool _insecure = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final creds = await ref.read(credentialStoreProvider).loadTls();
    if (creds == null || !mounted) return;
    setState(() {
      _host.text = creds.host;
      _port.text = '${creds.port}';
      _cert.text = creds.clientCertPem;
      _key.text = creds.clientKeyPem;
      _ca.text = creds.caPem ?? '';
      _insecure = creds.insecure;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _cert.dispose();
    _key.dispose();
    _ca.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      messenger.showSnackBar(const SnackBar(content: Text('Enter a valid host and port (1-65535).')));
      return;
    }
    if (_cert.text.trim().isEmpty || _key.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Client certificate and key are required.')));
      return;
    }
    final caText = _ca.text.trim();
    final config = TlsConnectionConfig(
      host: host,
      port: port,
      clientCertPem: _cert.text,
      clientKeyPem: _key.text,
      caPem: caText.isEmpty ? null : caText,
      insecure: _insecure,
    );
    final Transport transport;
    try {
      transport = config.build();
    } on TlsConfigException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Invalid certificate: ${e.message}')));
      return;
    }
    ref.read(transportProvider.notifier).state = transport;
    await ref.read(credentialStoreProvider).saveTls(TlsCredentials(
          host: host,
          port: port,
          clientCertPem: _cert.text,
          clientKeyPem: _key.text,
          caPem: caText.isEmpty ? null : caText,
          insecure: _insecure,
        ));
    navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _cert, decoration: const InputDecoration(labelText: 'Client certificate (PEM)'), maxLines: 4),
        TextField(controller: _key, decoration: const InputDecoration(labelText: 'Client key (PEM)'), maxLines: 4),
        TextField(controller: _ca, decoration: const InputDecoration(labelText: 'CA certificate (PEM, optional)'), maxLines: 4),
        SwitchListTile(
          title: const Text('Allow insecure (skip server verification)'),
          value: _insecure,
          onChanged: (v) => setState(() => _insecure = v),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _connect, child: const Text('Connect')),
      ],
    );
  }
}
