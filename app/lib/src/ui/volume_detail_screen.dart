import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class VolumeDetailScreen extends ConsumerWidget {
  final String volumeName;
  const VolumeDetailScreen({super.key, required this.volumeName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(volumeDetailProvider(volumeName));
    return Scaffold(
      appBar: AppBar(title: Text(volumeName)),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (v) {
          final client = ref.read(dockerClientProvider);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${v.driver} · ${v.scope}'),
              Text('Mountpoint: ${v.mountpoint}'),
              if (v.createdAt.isNotEmpty) Text('Created: ${v.createdAt}'),
              if (v.labels.isNotEmpty) ...[
                const Divider(),
                const Text('Labels', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in v.labels.entries) Text('${e.key} = ${e.value}'),
              ],
              if (v.options.isNotEmpty) ...[
                const Divider(),
                const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in v.options.entries) Text('${e.key} = ${e.value}'),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final navigator = Navigator.of(context);
                  final force = await _removeDialog(context);
                  if (force == null || client == null || !context.mounted) return;
                  try {
                    await client.removeVolume(volumeName, force: force);
                    ref.invalidate(volumesProvider);
                    navigator.pop();
                    messenger.showSnackBar(const SnackBar(content: Text('Removed')));
                  } catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
                  }
                },
                child: const Text('Remove'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Returns the force flag, or null if cancelled.
Future<bool?> _removeDialog(BuildContext context) {
  var force = false;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove volume?'),
        content: SwitchListTile(
          title: const Text('Force'),
          value: force,
          onChanged: (v) => setState(() => force = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, force), child: const Text('Remove')),
        ],
      ),
    ),
  );
}
