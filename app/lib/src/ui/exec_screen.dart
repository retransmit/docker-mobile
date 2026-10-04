import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/exec_session_controller.dart';
import '../state/providers.dart';
import '../transport/transport.dart';

class ExecScreen extends ConsumerStatefulWidget {
  final String containerId;
  final String containerName;
  const ExecScreen({super.key, required this.containerId, required this.containerName});

  @override
  ConsumerState<ExecScreen> createState() => _ExecScreenState();
}

class _ExecScreenState extends ConsumerState<ExecScreen> {
  ExecSessionController? _session;

  /// The transport [_session] was started on. When the current transport is
  /// a different one, the session cannot be restarted in place.
  Transport? _sessionTransport;

  final _cmd = TextEditingController();

  @override
  void initState() {
    super.initState();
    _newSession();
  }

  /// Starts a fresh exec on the current connection with the typed command
  /// (blank = the default shell).
  void _newSession() {
    final old = _session;
    old?.removeListener(_onChange);
    old?.dispose();
    final client = ref.read(dockerClientProvider);
    _sessionTransport = ref.read(transportProvider);
    _session = client == null
        ? null
        : (ExecSessionController(client, widget.containerId, command: _cmd.text)..addListener(_onChange));
    if (old != null) setState(() {});
  }

  /// Runs the typed command: in place while the session's connection is
  /// still the current one, otherwise as a new session.
  void _run() {
    final session = _session;
    if (session == null || !identical(_sessionTransport, ref.read(transportProvider))) {
      _newSession();
    } else {
      session.restart(_cmd.text);
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
    ref.listen<Transport?>(transportProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) _session?.end();
    });
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: Text(widget.containerName)),
      body: session == null
          ? const Center(child: Text('Not connected'))
          : Column(
              children: [
                _CommandBar(controller: _cmd, onRun: _run),
                if (session.status == ExecStatus.error)
                  MaterialBanner(
                    content: const Text('Exec failed'),
                    actions: [TextButton(onPressed: _newSession, child: const Text('Retry'))],
                  ),
                if (session.status == ExecStatus.ended)
                  MaterialBanner(
                    content: Text('Session ended${session.exitCode != null ? ' (exit ${session.exitCode})' : ''}'),
                    actions: [TextButton(onPressed: _newSession, child: const Text('New session'))],
                  ),
                Expanded(child: TerminalView(session.terminal, key: ObjectKey(session))),
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
