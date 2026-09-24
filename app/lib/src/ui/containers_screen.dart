import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_theme.dart';
import 'container_detail_screen.dart';
import 'create_container_screen.dart';
import 'widgets/error_view.dart';
import 'widgets/resource_widgets.dart';
import 'widgets/skeletons.dart';

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
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: containers.when(
          loading: () => const SkeletonList(key: ValueKey('loading')),
          error: (e, _) => RefreshIndicator(
            key: const ValueKey('error'),
            onRefresh: () async {
              try {
                ref.invalidate(containersProvider);
                await ref.read(containersProvider.future);
              } catch (_) {}
            },
            child: ErrorView(error: e, scrollable: true, onRetry: () => ref.invalidate(containersProvider), busy: containers.isRefreshing),
          ),
          data: (list) => RefreshIndicator(
            key: const ValueKey('data'),
            onRefresh: () async {
              ref.invalidate(containersProvider);
              await ref.read(containersProvider.future);
            },
            child: list.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(
                        height: 480,
                        child: EmptyState(icon: Icons.inventory_2, title: 'No containers', message: 'This daemon has no containers yet.'),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
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
        ),
      ),
    );
  }
}
