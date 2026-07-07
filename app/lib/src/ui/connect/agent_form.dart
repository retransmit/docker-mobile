import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connection_launcher.dart';
import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../storage/profile_store.dart';
import '../widgets/app_text_field.dart';

class AgentForm extends ConsumerStatefulWidget {
  final ConnectionProfile? editing;
  const AgentForm({super.key, this.editing});
  @override
  ConsumerState<AgentForm> createState() => _AgentFormState();
}

class _AgentFormState extends ConsumerState<AgentForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _token = TextEditingController();
  bool _useTls = false;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e?.agent != null) {
      _name.text = e!.name;
      final uri = Uri.tryParse(e.agent!.baseUri);
      _host.text = uri?.host ?? '';
      _port.text = '${uri?.port ?? 8080}';
      _token.text = e.agent!.token;
      _useTls = uri?.scheme == 'https';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  ConnectionProfile? _build() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (name.isEmpty || host.isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a name, host, and port (1-65535).')));
      return null;
    }
    final baseUri = Uri(scheme: _useTls ? 'https' : 'http', host: host, port: port);
    return ConnectionProfile(
      id: widget.editing?.id ?? newProfileId(),
      name: name,
      kind: ConnectionKind.agent,
      agent: AgentCredentials(baseUri: baseUri.toString(), token: _token.text),
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
      children: [
        AppTextField(controller: _name, label: 'Name', icon: Icons.label),
        AppTextField(controller: _host, label: 'Host / IP', icon: Icons.dns),
        AppTextField(controller: _port, label: 'Port', icon: Icons.numbers, keyboardType: TextInputType.number),
        AppTextField(controller: _token, label: 'Token', icon: Icons.key, obscure: true, last: true, onSubmit: _saveAndConnect),
        SwitchListTile(title: const Text('Use TLS (https)'), value: _useTls, onChanged: (v) => setState(() => _useTls = v)),
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
