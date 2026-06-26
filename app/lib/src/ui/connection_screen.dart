import 'package:flutter/material.dart';

import '../storage/profile_store.dart';
import 'connect/agent_form.dart';
import 'connect/ssh_form.dart';
import 'connect/tls_form.dart';

class ConnectionScreen extends StatefulWidget {
  final ConnectionProfile? editing;
  const ConnectionScreen({super.key, this.editing});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  late ConnectionKind _kind = widget.editing?.kind ?? ConnectionKind.agent;

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing;
    return Scaffold(
      appBar: AppBar(title: Text(editing == null ? 'Add connection' : 'Edit ${editing.name}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (editing == null)
              SegmentedButton<ConnectionKind>(
                segments: const [
                  ButtonSegment(value: ConnectionKind.agent, label: Text('Agent'), icon: Icon(Icons.dns)),
                  ButtonSegment(value: ConnectionKind.tls, label: Text('TCP+TLS'), icon: Icon(Icons.lock)),
                  ButtonSegment(value: ConnectionKind.ssh, label: Text('SSH'), icon: Icon(Icons.terminal)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: switch (_kind) {
                  ConnectionKind.agent => AgentForm(editing: editing),
                  ConnectionKind.tls => TlsForm(editing: editing),
                  ConnectionKind.ssh => SshForm(editing: editing),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
