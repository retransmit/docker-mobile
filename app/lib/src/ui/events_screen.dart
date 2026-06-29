import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/events_notifier.dart';
import 'widgets/resource_widgets.dart';

class EventsScreen extends ConsumerWidget {
  const EventsScreen({super.key});

  static const List<(String?, String)> _chips = [
    (null, 'All'),
    ('container', 'Containers'),
    ('image', 'Images'),
    ('network', 'Networks'),
    ('volume', 'Volumes'),
  ];

  IconData _icon(String type) => switch (type) {
        'container' => Icons.inventory,
        'image' => Icons.layers,
        'network' => Icons.hub,
        'volume' => Icons.storage,
        _ => Icons.bolt,
      };

  String _time(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(eventsProvider);
    final notifier = ref.read(eventsProvider.notifier);
    final visible = state.visibleEvents;
    return Scaffold(
      appBar: AppBar(title: const Text('Events')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (type, label) in _chips)
                  FilterChip(
                    label: Text(label),
                    selected: state.filterType == type,
                    onSelected: (_) => notifier.setFilter(type),
                  ),
              ],
            ),
          ),
          Expanded(
            child: state.status == EventsStatus.error
                ? Center(child: Text('Error: ${state.error}'))
                : visible.isEmpty
                    ? const EmptyState(
                        icon: Icons.bolt,
                        title: 'No events yet',
                        message: 'Events appear here as activity happens on the daemon.',
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final e = visible[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(_icon(e.type)),
                            title: Text('${e.type} · ${e.action}'),
                            subtitle: Text(e.target),
                            trailing: Text(_time(e.time)),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
