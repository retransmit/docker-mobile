import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/container_detail.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'widgets/resource_widgets.dart';
import 'logs_screen.dart';
import 'exec_screen.dart';
import 'container_stats_screen.dart';

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
    final status = StatusColors.of(context);
    final color = s.paused ? status.paused : (s.running ? status.running : status.stopped);
    final label = s.paused
        ? 'paused'
        : (!s.running && s.exitCode != null ? '${s.status} (exit ${s.exitCode})' : s.status);
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Hero
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusPill(label: label, color: color),
                const SizedBox(height: 12),
                MonoText(detail.image, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Promoted read-only actions
        Row(
          children: [
            Expanded(child: FilledButton.tonalIcon(
              icon: const Icon(Icons.article),
              label: const Text('Logs'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => LogsScreen(containerId: containerId, containerName: containerName))),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(
              icon: const Icon(Icons.terminal),
              label: const Text('Exec'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ExecScreen(containerId: containerId, containerName: containerName))),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(
              icon: const Icon(Icons.monitor_heart),
              label: const Text('Stats'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ContainerStatsScreen(containerId: containerId, containerName: containerName))),
            )),
          ],
        ),
        const SizedBox(height: 16),
        // Configuration
        if (detail.created.isNotEmpty || detail.command.isNotEmpty || detail.restartPolicy.isNotEmpty)
          _InfoCard('Configuration', [
            if (detail.created.isNotEmpty) _InfoRow('Created', detail.created),
            if (detail.command.isNotEmpty) _InfoRow('Command', detail.command, mono: true),
            if (detail.restartPolicy.isNotEmpty) _InfoRow('Restart policy', detail.restartPolicy),
          ]),
        // Networking
        if (detail.networks.isNotEmpty || detail.ports.isNotEmpty)
          _InfoCard('Networking', [
            if (detail.networks.isNotEmpty) _InfoRow('Networks', detail.networks.join(', ')),
            if (detail.ports.isNotEmpty)
              _InfoRow('Ports',
                  detail.ports.map((p) => '${p.publicPort != null ? '${p.publicPort}->' : ''}${p.privatePort}/${p.type}').join(', '),
                  mono: true),
          ]),
        // Storage
        if (detail.mounts.isNotEmpty)
          _InfoCard('Storage', [
            _InfoRow('Mounts', detail.mounts.map((m) => '${m.source}:${m.destination}${m.rw ? '' : ' (ro)'}').join('\n'), mono: true),
          ]),
        // Environment (collapsed)
        if (detail.env.isNotEmpty) _EnvCard(env: detail.env),
        const SizedBox(height: 8),
        // Lifecycle actions (restyled in Task 2)
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
      ],
    );
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

class _InfoCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _InfoCard(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  const _InfoRow(this.label, this.value, {this.mono = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          mono
              ? MonoText(value, style: text.bodyMedium)
              : Text(value, style: text.bodyMedium),
        ],
      ),
    );
  }
}

class _EnvCard extends StatelessWidget {
  final List<String> env;
  const _EnvCard({required this.env});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('Environment (${env.length})', style: text.titleMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final e in env) MonoText(e, style: text.bodySmall)],
        ),
      ),
    );
  }
}
