import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/disconnect.dart';
import '../state/providers.dart';
import 'events_screen.dart';
import 'widgets/resource_widgets.dart';

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class SystemScreen extends ConsumerWidget {
  const SystemScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(systemDashboardProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('System'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(systemDashboardProvider)),
          IconButton(
            icon: const Icon(Icons.bolt),
            tooltip: 'Events',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EventsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Disconnect',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Disconnect'),
                  content: const Text('Disconnect from this daemon?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) await disconnect(context, ref);
            },
          ),
        ],
      ),
      body: dash.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          final info = d.info;
          final v = d.version;
          final df = d.df;
          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: StatCard(icon: Icons.inventory_2, value: '${info.containersRunning}', label: 'Containers', sub: 'of ${info.containers} total')),
                          const SizedBox(width: 12),
                          Expanded(child: StatCard(icon: Icons.layers, value: '${info.images}', label: 'Images')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: StatCard(icon: Icons.storage, value: '${df.volumes.count}', label: 'Volumes')),
                          const SizedBox(width: 12),
                          Expanded(child: StatCard(icon: Icons.pie_chart, value: _humanSize(df.total), label: 'Disk used')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _card('Daemon', [
                      _kv2(context, 'Version', info.serverVersion),
                      _kv2(context, 'API', v.apiVersion),
                      _kv2(context, 'OS / Arch', '${info.osType} / ${info.architecture}'),
                      _kv2(context, 'Kernel', info.kernelVersion),
                      _kv2(context, 'CPUs', '${info.ncpu}'),
                      _kv2(context, 'Memory', _humanSize(info.memTotal)),
                      _kv2(context, 'Storage driver', info.storageDriver),
                    ]),
                    _card('Disk usage', [
                      for (final c in [df.images, df.containers, df.volumes, df.buildCache])
                        _kv2(context, '${c.name} (${c.count})', _humanSize(c.size), mono: true),
                      _kv2(context, 'Total', _humanSize(df.total), mono: true),
                    ]),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => _prune(context, ref),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cleaning_services),
                        SizedBox(width: 8),
                        Text('System prune'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final opts = await _pruneDialog(context);
    if (opts == null) return;
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    try {
      await client.systemPrune(allImages: opts.$1, includeVolumes: opts.$2);
      ref.invalidate(systemDashboardProvider);
      ref.invalidate(containersProvider);
      ref.invalidate(imagesProvider);
      ref.invalidate(networksProvider);
      ref.invalidate(volumesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Widget _card(String title, List<Widget> rows) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ...rows,
            ],
          ),
        ),
      );

  Widget _kv2(BuildContext context, String label, String value, {bool mono = false}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          mono ? MonoText(value, style: text.bodyMedium) : Text(value, style: text.bodyMedium),
        ],
      ),
    );
  }
}

/// Returns (allImages, includeVolumes), or null if cancelled.
Future<(bool, bool)?> _pruneDialog(BuildContext context) {
  var allImages = false;
  var includeVolumes = false;
  return showDialog<(bool, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('System prune'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Removes stopped containers, unused networks, dangling images, and build cache.'),
            SwitchListTile(title: const Text('All unused images'), value: allImages, onChanged: (val) => setState(() => allImages = val)),
            SwitchListTile(title: const Text('Also unused volumes'), value: includeVolumes, onChanged: (val) => setState(() => includeVolumes = val)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (allImages, includeVolumes)), child: const Text('Prune')),
        ],
      ),
    ),
  );
}
