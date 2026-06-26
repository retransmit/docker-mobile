import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'network_create_sheet.dart';
import 'network_detail_screen.dart';
import 'widgets/resource_widgets.dart';

class NetworksScreen extends ConsumerWidget {
  const NetworksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final networks = ref.watch(networksProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Networks'),
        actions: [
          IconButton(
            tooltip: 'Create',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NetworkCreateSheet())),
          ),
          IconButton(tooltip: 'Prune', icon: const Icon(Icons.cleaning_services), onPressed: () => _prune(context, ref)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(networksProvider)),
        ],
      ),
      body: networks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final n = list[i];
            return Card(
              child: ListTile(
                leading: const LeadingAvatar(icon: Icons.hub),
                title: Text(n.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [MetaChip(n.driver), const SizedBox(width: 8), MetaChip(n.scope)]),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => NetworkDetailScreen(networkId: n.id, title: n.name)),
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
        title: const Text('Prune networks'),
        content: const Text('Remove all unused networks?'),
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
      await client.pruneNetworks();
      ref.invalidate(networksProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
