import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connection_launcher.dart';
import '../state/providers.dart';
import '../storage/profile_store.dart';
import 'connection_screen.dart';

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
      appBar: AppBar(title: const Text('Connections')),
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
                    ListTile(
                      leading: Icon(_icon(p.kind)),
                      title: Text(p.name),
                      subtitle: Text('${p.kind.name} · ${p.host}'),
                      onTap: () => launchConnection(context, ref, p),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => ConnectionScreen(editing: p)));
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
                ],
              ),
      ),
    );
  }
}
