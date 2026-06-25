import 'package:flutter/material.dart';

import 'connect/agent_form.dart';
import 'connect/tls_form.dart';

enum _TransportType { agent, tls }

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  _TransportType _type = _TransportType.agent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SegmentedButton<_TransportType>(
              segments: const [
                ButtonSegment(value: _TransportType.agent, label: Text('Agent'), icon: Icon(Icons.dns)),
                ButtonSegment(value: _TransportType.tls, label: Text('TCP+TLS'), icon: Icon(Icons.lock)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: _type == _TransportType.agent ? const AgentForm() : const TlsForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
