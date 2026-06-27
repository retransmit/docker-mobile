import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'volume_create_sheet.dart';
import 'volume_detail_screen.dart';
import 'widgets/resource_widgets.dart';

class VolumesScreen extends ConsumerWidget {
  const VolumesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volumes = ref.watch(volumesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Volumes'),
        actions: [
          IconButton(
            tooltip: 'Create',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VolumeCreateSheet())),
          ),
          IconButton(tooltip: 'Prune', icon: const Icon(Icons.cleaning_services), onPressed: () => _prune(context, ref)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(volumesProvider)),
        ],
      ),
      body: volumes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.storage, title: 'No volumes')
            : ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final v = list[i];
            return Card(
              child: ListTile(
                leading: const LeadingAvatar(icon: Icons.storage),
                title: MonoText(v.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: MonoText(v.mountpoint, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                trailing: MetaChip(v.driver),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => VolumeDetailScreen(volumeName: v.name)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prune volumes'),
        content: const Text('Remove all unused (anonymous) volumes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Prune')),
        ],
      ),
    );
    if (ok != true) return;
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    try {
      await client.pruneVolumes();
      ref.invalidate(volumesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
