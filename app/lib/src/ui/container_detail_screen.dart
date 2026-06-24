import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/container_detail.dart';
import '../state/providers.dart';
import 'logs_screen.dart';
import 'exec_screen.dart';

class ContainerDetailScreen extends ConsumerWidget {
  final String containerId;
  final String containerName;
  const ContainerDetailScreen({super.key, required this.containerId, required this.containerName});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, String okMsg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref.invalidate(containerDetailProvider(containerId));
      ref.invalidate(containersProvider);
      messenger.showSnackBar(SnackBar(content: Text(okMsg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(containerDetailProvider(containerId));
    return Scaffold(
      appBar: AppBar(
        title: Text(containerName),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(containerDetailProvider(containerId))),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (c) => _Body(detail: c, containerId: containerId, containerName: containerName, onRun: _run),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final ContainerDetail detail;
  final String containerId;
  final String containerName;
  final Future<void> Function(BuildContext, WidgetRef, Future<void> Function(), String) onRun;
  const _Body({required this.detail, required this.containerId, required this.containerName, required this.onRun});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.read(dockerClientProvider)!;
    final s = detail.state;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StateBadge(state: s),
        const SizedBox(height: 12),
        _kv('Image', detail.image),
        if (detail.command.isNotEmpty) _kv('Command', detail.command),
        if (detail.created.isNotEmpty) _kv('Created', detail.created),
        if (detail.restartPolicy.isNotEmpty) _kv('Restart policy', detail.restartPolicy),
        if (detail.networks.isNotEmpty) _kv('Networks', detail.networks.join(', ')),
        if (detail.ports.isNotEmpty)
          _kv('Ports', detail.ports.map((p) => '${p.publicPort != null ? '${p.publicPort}->' : ''}${p.privatePort}/${p.type}').join(', ')),
        if (detail.mounts.isNotEmpty)
          _kv('Mounts', detail.mounts.map((m) => '${m.source}:${m.destination}${m.rw ? '' : ' (ro)'}').join('\n')),
        if (detail.env.isNotEmpty) _kv('Env', detail.env.join('\n')),
        const Divider(height: 32),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!s.running)
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.startContainer(containerId), 'Started'), child: const Text('Start')),
            if (s.running && !s.paused) ...[
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.stopContainer(containerId), 'Stopped'), child: const Text('Stop')),
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.restartContainer(containerId), 'Restarted'), child: const Text('Restart')),
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.pauseContainer(containerId), 'Paused'), child: const Text('Pause')),
            ],
            if (s.paused)
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.unpauseContainer(containerId), 'Unpaused'), child: const Text('Unpause')),
            if (s.running)
              ElevatedButton(
                onPressed: () async {
                  if (await _confirm(context, 'Kill container?', 'Sends SIGKILL immediately.') && context.mounted) {
                    await onRun(context, ref, () => client.killContainer(containerId), 'Killed');
                  }
                },
                child: const Text('Kill'),
              ),
            OutlinedButton(
              onPressed: () async {
                final name = await _renameDialog(context, containerName);
                if (name != null && name.isNotEmpty && context.mounted) {
                  await onRun(context, ref, () => client.renameContainer(containerId, name), 'Renamed');
                }
              },
              child: const Text('Rename'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer),
              onPressed: () async {
                final opts = await _removeDialog(context);
                if (opts != null && context.mounted) {
                  await onRun(context, ref,
                      () => client.removeContainer(containerId, force: opts.$1, removeVolumes: opts.$2), 'Removed');
                }
              },
              child: const Text('Remove'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.article),
              label: const Text('Logs'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => LogsScreen(containerId: containerId, containerName: containerName))),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.terminal),
              label: const Text('Exec'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ExecScreen(containerId: containerId, containerName: containerName))),
            )),
          ],
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}

class _StateBadge extends StatelessWidget {
  final ContainerStateInfo state;
  const _StateBadge({required this.state});
  @override
  Widget build(BuildContext context) {
    final running = state.running;
    final color = state.paused ? Colors.orange : (running ? Colors.green : Colors.grey);
    final label = state.paused ? 'paused' : state.status;
    return Row(children: [
      Icon(Icons.circle, size: 12, color: color),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      if (!running && state.exitCode != null) Text('  (exit ${state.exitCode})'),
    ]);
  }
}

Future<bool> _confirm(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
      ],
    ),
  );
  return ok ?? false;
}

Future<String?> _renameDialog(BuildContext context, String current) =>
    showDialog<String>(context: context, builder: (_) => _RenameDialog(current: current));

class _RenameDialog extends StatefulWidget {
  final String current;
  const _RenameDialog({required this.current});
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _ctl = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rename container'),
        content: TextField(controller: _ctl, autofocus: true, decoration: const InputDecoration(labelText: 'New name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, _ctl.text), child: const Text('Rename')),
        ],
      );
}

/// Returns (force, removeVolumes) or null if cancelled.
Future<(bool, bool)?> _removeDialog(BuildContext context) {
  var force = false;
  var removeVolumes = false;
  return showDialog<(bool, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove container?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(title: const Text('Force'), value: force, onChanged: (v) => setState(() => force = v)),
            SwitchListTile(title: const Text('Remove volumes'), value: removeVolumes, onChanged: (v) => setState(() => removeVolumes = v)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (force, removeVolumes)), child: const Text('Remove')),
        ],
      ),
    ),
  );
}
