import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class NetworkDetailScreen extends ConsumerWidget {
  final String networkId;
  final String title;
  const NetworkDetailScreen({super.key, required this.networkId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(networkDetailProvider(networkId));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          final client = ref.read(dockerClientProvider);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${d.driver} · ${d.scope}'),
              Text('Internal: ${d.internal}  ·  Attachable: ${d.attachable}  ·  IPv6: ${d.enableIPv6}'),
              const Divider(),
              const Text('IPAM', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final c in d.ipam) Text('${c.subnet ?? '-'}  gw ${c.gateway ?? '-'}${c.ipRange != null ? '  range ${c.ipRange}' : ''}'),
              const Divider(),
              const Text('Connected containers', style: TextStyle(fontWeight: FontWeight.bold)),
              if (d.containers.isEmpty) const Text('none')
              else for (final c in d.containers) Text('${c.name}  ${c.ipv4}'),
              if (d.labels.isNotEmpty) ...[
                const Divider(),
                const Text('Labels', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in d.labels.entries) Text('${e.key} = ${e.value}'),
              ],
              if (d.options.isNotEmpty) ...[
                const Divider(),
                const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in d.options.entries) Text('${e.key} = ${e.value}'),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final navigator = Navigator.of(context);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Remove network?'),
                      content: Text('Remove "$title"?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                      ],
                    ),
                  );
                  if (ok != true || client == null) return;
                  try {
                    await client.removeNetwork(networkId);
                    ref.invalidate(networksProvider);
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
