import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connection_launcher.dart';
import '../state/providers.dart';
import '../storage/profile_store.dart';
import 'connection_screen.dart';
import 'settings_screen.dart';
import 'widgets/resource_widgets.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  IconData _icon(ConnectionKind k) => switch (k) {
        ConnectionKind.agent => Icons.dns,
        ConnectionKind.tls => Icons.lock,
        ConnectionKind.ssh => Icons.terminal,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
        child: const Icon(Icons.add),
      ),
      body: profiles.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No saved connections — tap + to add one.'))
            : ListView(
                children: [
                  for (final p in list)
                    Card(
                      child: ListTile(
                        leading: LeadingAvatar(icon: _icon(p.kind)),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Row(
                          children: [
                            MetaChip(p.kind.name),
                            const SizedBox(width: 8),
                            Expanded(child: MonoText(p.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
                          ],
                        ),
                        onTap: () => launchConnection(context, ref, p),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'edit') {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConnectionScreen(editing: p)));
                            } else if (v == 'delete') {
                              await ref.read(profileStoreProvider).delete(p.id);
                              ref.invalidate(profilesProvider);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
