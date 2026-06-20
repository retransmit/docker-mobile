import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'logs_screen.dart';

class ContainersScreen extends ConsumerWidget {
  const ContainersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final containers = ref.watch(containersProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Containers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(containersProvider),
          ),
        ],
      ),
      body: containers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final c = list[i];
            final name = c.names.isNotEmpty ? c.names.first : c.id;
            return ListTile(
              leading: Icon(
                c.state == 'running' ? Icons.play_circle : Icons.stop_circle,
                color: c.state == 'running' ? Colors.green : Colors.grey,
              ),
              title: Text(name),
              subtitle: Text('${c.image} · ${c.status}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LogsScreen(containerId: c.id, containerName: name),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
