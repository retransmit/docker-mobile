import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connection_launcher.dart';
import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../storage/profile_store.dart';

class SshForm extends ConsumerStatefulWidget {
  final ConnectionProfile? editing;
  const SshForm({super.key, this.editing});
  @override
  ConsumerState<SshForm> createState() => _SshFormState();
}

class _SshFormState extends ConsumerState<SshForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  SshAuthMethod _authMethod = SshAuthMethod.password;
  String? _pinnedHostKey;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e?.ssh != null) {
      _name.text = e!.name;
      final s = e.ssh!;
      _host.text = s.host;
      _port.text = '${s.port}';
      _username.text = s.username;
      _authMethod = s.authMethod;
      _password.text = s.password ?? '';
      _key.text = s.privateKeyPem ?? '';
      _passphrase.text = s.passphrase ?? '';
      _pinnedHostKey = s.pinnedHostKey;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  ConnectionProfile? _build() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final user = _username.text.trim();
    if (name.isEmpty || host.isEmpty || port == null || port < 1 || port > 65535 || user.isEmpty) {
      _snack('Enter a name, host, port (1-65535), and username.');
      return null;
    }
    if (_authMethod == SshAuthMethod.key && _key.text.trim().isEmpty) {
      _snack('A private key is required for key auth.');
      return null;
    }
    if (_authMethod == SshAuthMethod.password && _password.text.isEmpty) {
      _snack('A password is required for password auth.');
      return null;
    }
    return ConnectionProfile(
      id: widget.editing?.id ?? newProfileId(),
      name: name,
      kind: ConnectionKind.ssh,
      ssh: SshCredentials(
        host: host, port: port, username: user, authMethod: _authMethod,
        password: _authMethod == SshAuthMethod.password ? _password.text : null,
        privateKeyPem: _authMethod == SshAuthMethod.key ? _key.text : null,
        passphrase: _authMethod == SshAuthMethod.key && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        pinnedHostKey: _pinnedHostKey,
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
        TextField(controller: _username, decoration: const InputDecoration(labelText: 'Username')),
        const SizedBox(height: 8),
        SegmentedButton<SshAuthMethod>(
          segments: const [
            ButtonSegment(value: SshAuthMethod.password, label: Text('Password')),
            ButtonSegment(value: SshAuthMethod.key, label: Text('Key')),
          ],
          selected: {_authMethod},
          onSelectionChanged: (s) => setState(() => _authMethod = s.first),
        ),
        if (_authMethod == SshAuthMethod.password)
          TextField(controller: _password, decoration: const InputDecoration(labelText: 'Password'), obscureText: true)
        else ...[
          TextField(controller: _key, decoration: const InputDecoration(labelText: 'Private key (PEM)'), maxLines: 4),
          TextField(controller: _passphrase, decoration: const InputDecoration(labelText: 'Passphrase (optional)'), obscureText: true),
        ],
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
