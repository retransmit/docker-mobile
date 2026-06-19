import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../transport/agent_transport.dart';
import 'containers_screen.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _token = TextEditingController();
  bool _useTls = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _connect() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid host and port (1-65535).')),
      );
      return;
    }
    // Build the URI from validated parts (no Uri.parse on raw input).
    final baseUri = Uri(scheme: _useTls ? 'https' : 'http', host: host, port: port);
    ref.read(transportProvider.notifier).state =
        AgentTransport(baseUri: baseUri, token: _token.text);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ContainersScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
            TextField(
              controller: _port,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: _token,
              decoration: const InputDecoration(labelText: 'Token'),
              obscureText: true,
            ),
            SwitchListTile(
              title: const Text('Use TLS (https)'),
              value: _useTls,
              onChanged: (v) => setState(() => _useTls = v),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _connect, child: const Text('Connect')),
          ],
        ),
      ),
    );
  }
}
