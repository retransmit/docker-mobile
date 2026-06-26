import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connection_launcher.dart';
import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../storage/profile_store.dart';

class TlsForm extends ConsumerStatefulWidget {
  final ConnectionProfile? editing;
  const TlsForm({super.key, this.editing});
  @override
  ConsumerState<TlsForm> createState() => _TlsFormState();
}

class _TlsFormState extends ConsumerState<TlsForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '2376');
  final _cert = TextEditingController();
  final _key = TextEditingController();
  final _ca = TextEditingController();
  bool _insecure = false;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e?.tls != null) {
      _name.text = e!.name;
      final t = e.tls!;
      _host.text = t.host;
      _port.text = '${t.port}';
      _cert.text = t.clientCertPem;
      _key.text = t.clientKeyPem;
      _ca.text = t.caPem ?? '';
      _insecure = t.insecure;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _cert.dispose();
    _key.dispose();
    _ca.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  ConnectionProfile? _build() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (name.isEmpty || host.isEmpty || port == null || port < 1 || port > 65535) {
      _snack('Enter a name, host, and port (1-65535).');
      return null;
    }
    if (_cert.text.trim().isEmpty || _key.text.trim().isEmpty) {
      _snack('Client certificate and key are required.');
      return null;
    }
    final ca = _ca.text.trim();
    return ConnectionProfile(
      id: widget.editing?.id ?? newProfileId(),
      name: name,
      kind: ConnectionKind.tls,
      tls: TlsCredentials(
        host: host, port: port,
        clientCertPem: _cert.text, clientKeyPem: _key.text,
        caPem: ca.isEmpty ? null : ca, insecure: _insecure,
      ),
    );
  }

  Future<void> _persist(ConnectionProfile p) async {
    final store = ref.read(profileStoreProvider);
    widget.editing == null ? await store.add(p) : await store.update(p);
    ref.invalidate(profilesProvider);
  }

  Future<void> _save() async {
    final p = _build();
    if (p == null) return;
    final navigator = Navigator.of(context);
    await _persist(p);
    navigator.pop();
  }

  Future<void> _saveAndConnect() async {
    final p = _build();
    if (p == null) return;
    await _persist(p);
    if (!mounted) return;
    await launchConnection(context, ref, p);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _cert, decoration: const InputDecoration(labelText: 'Client certificate (PEM)'), maxLines: 4),
        TextField(controller: _key, decoration: const InputDecoration(labelText: 'Client key (PEM)'), maxLines: 4),
        TextField(controller: _ca, decoration: const InputDecoration(labelText: 'CA certificate (PEM, optional)'), maxLines: 4),
        SwitchListTile(title: const Text('Allow insecure (skip server verification)'), value: _insecure, onChanged: (v) => setState(() => _insecure = v)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _save, child: const Text('Save'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _saveAndConnect, child: const Text('Save & Connect'))),
        ]),
      ],
    );
  }
}
