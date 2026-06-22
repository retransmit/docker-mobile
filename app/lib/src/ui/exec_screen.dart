import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/exec_session_controller.dart';
import '../state/providers.dart';

class ExecScreen extends ConsumerStatefulWidget {
  final String containerId;
  final String containerName;
  const ExecScreen({super.key, required this.containerId, required this.containerName});

  @override
  ConsumerState<ExecScreen> createState() => _ExecScreenState();
}

class _ExecScreenState extends ConsumerState<ExecScreen> {
  ExecSessionController? _session;
  final _cmd = TextEditingController();

  @override
  void initState() {
    super.initState();
    final client = ref.read(dockerClientProvider);
    if (client != null) {
      _session = ExecSessionController(client, widget.containerId)..addListener(_onChange);
    }
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _session?.removeListener(_onChange);
    _session?.dispose();
    _cmd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: Text(widget.containerName)),
      body: session == null
          ? const Center(child: Text('Not connected'))
          : Column(
              children: [
                _CommandBar(controller: _cmd, onRun: () => session.restart(_cmd.text)),
                if (session.status == ExecStatus.error)
                  MaterialBanner(
                    content: const Text('Exec failed'),
                    actions: [TextButton(onPressed: () => session.restart(_cmd.text), child: const Text('Retry'))],
                  ),
                if (session.status == ExecStatus.ended)
                  MaterialBanner(
                    content: Text('Session ended${session.exitCode != null ? ' (exit ${session.exitCode})' : ''}'),
                    actions: [TextButton(onPressed: () => session.restart(_cmd.text), child: const Text('Restart'))],
                  ),
                Expanded(child: TerminalView(session.terminal)),
              ],
            ),
    );
  }
}

class _CommandBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onRun;
  const _CommandBar({required this.controller, required this.onRun});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Command (blank = auto shell)',
                isDense: true,
              ),
            ),
          ),
          IconButton(tooltip: 'Run', icon: const Icon(Icons.play_arrow), onPressed: onRun),
        ],
      ),
    );
  }
}
