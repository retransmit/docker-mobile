import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'container_detail_screen.dart';
import 'create_container_screen.dart';
import 'widgets/resource_widgets.dart';

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
      floatingActionButton: FloatingActionButton(
        tooltip: 'Create container',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CreateContainerScreen()),
        ),
        child: const Icon(Icons.add),
      ),
      body: containers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final c = list[i];
            final name = c.names.isNotEmpty ? c.names.first : c.id;
            final sc = StatusColors.of(context);
            final color = c.state == 'running'
                ? sc.running
                : c.state == 'paused'
                    ? sc.paused
                    : sc.stopped;
            return Card(
              child: ListTile(
                isThreeLine: true,
                leading: LeadingAvatar(
                  icon: c.state == 'running' ? Icons.play_arrow_rounded : Icons.stop_rounded,
                  background: color.withValues(alpha: 0.18),
                  foreground: color,
                ),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MonoText(c.image, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                    Text(c.status, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                trailing: StatusPill(label: c.state, color: color),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ContainerDetailScreen(containerId: c.id, containerName: name)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
