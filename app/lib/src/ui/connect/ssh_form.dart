import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../transport/ssh/host_key.dart';
import '../../transport/ssh/ssh_transport.dart';
import '../home_screen.dart';

class SshForm extends ConsumerStatefulWidget {
  const SshForm({super.key});
  @override
  ConsumerState<SshForm> createState() => _SshFormState();
}

class _SshFormState extends ConsumerState<SshForm> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  SshAuthMethod _authMethod = SshAuthMethod.password;
  String? _pinnedHostKey;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final creds = await ref.read(credentialStoreProvider).loadSsh();
    if (creds == null || !mounted) return;
    setState(() {
      _host.text = creds.host;
      _port.text = '${creds.port}';
      _username.text = creds.username;
      _authMethod = creds.authMethod;
      _password.text = creds.password ?? '';
      _key.text = creds.privateKeyPem ?? '';
      _passphrase.text = creds.passphrase ?? '';
      _pinnedHostKey = creds.pinnedHostKey;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  SshCredentials _buildCreds(String? pin) => SshCredentials(
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
        authMethod: _authMethod,
        password: _authMethod == SshAuthMethod.password ? _password.text : null,
        privateKeyPem: _authMethod == SshAuthMethod.key ? _key.text : null,
        passphrase: _authMethod == SshAuthMethod.key && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        pinnedHostKey: pin,
      );

  void _connect() {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final user = _username.text.trim();
    if (host.isEmpty || port == null || port < 1 || port > 65535 || user.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Enter a valid host, port (1-65535), and username.')));
      return;
    }
    if (_authMethod == SshAuthMethod.key && _key.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('A private key is required for key auth.')));
      return;
    }
    if (_authMethod == SshAuthMethod.password && _password.text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('A password is required for password auth.')));
      return;
    }
    _attemptConnect(_pinnedHostKey, messenger, navigator);
  }

  Future<void> _attemptConnect(String? pin, ScaffoldMessengerState messenger, NavigatorState navigator) async {
    final creds = _buildCreds(pin);
    final conn = ref.read(sshConnectionFactoryProvider)(creds);
    String? presented;
    var mismatch = false;
    bool verifier(String fp) {
      presented = fp;
      if (verifyHostKey(pin, fp) == HostKeyVerdict.mismatch) {
        mismatch = true;
        return false;
      }
      return true;
    }

    setState(() => _connecting = true);
    try {
      await conn.connect(verifyHostKey: verifier);
    } catch (e) {
      await conn.close(); // reclaim the failed SSH client/socket (esp. on a host-key mismatch)
      if (!mounted) return;
      setState(() => _connecting = false);
      if (mismatch && presented != null) {
        final trust = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Host key changed'),
            content: const Text(
                'The server host key does not match the pinned key. This could be a man-in-the-middle attack. Trust the new key only if you expected this change.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Trust new key')),
            ],
          ),
        );
        if (trust == true && mounted) {
          await _attemptConnect(presented, messenger, navigator); // re-pin with the presented key
        }
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text('Connection failed: $e')));
      return;
    }
    if (!mounted) return;
    setState(() => _connecting = false);
    final newPin = pin ?? presented;
    // Persist best-effort; never block connecting.
    try {
      await ref.read(credentialStoreProvider).saveSsh(_buildCreds(newPin));
    } catch (_) {}
    if (!mounted) {
      await conn.close(); // disposed mid-connect — don't leak the live client
      return;
    }
    ref.read(transportProvider.notifier).state = SshTransport(openDuplex: conn.openChannel);
    navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        _connecting
            ? const Center(child: CircularProgressIndicator())
            : FilledButton(onPressed: _connect, child: const Text('Connect')),
      ],
    );
  }
}
