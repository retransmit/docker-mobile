import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'image_detail_screen.dart';
import 'pull_sheet.dart';
import 'widgets/resource_widgets.dart';

class ImagesScreen extends ConsumerWidget {
  const ImagesScreen({super.key});

  String _name(List<String> tags, String id) =>
      tags.isNotEmpty && tags.first != '<none>:<none>' ? tags.first : '<none> (${id.length > 19 ? id.substring(7, 19) : id})';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref.watch(imagesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Images'),
        actions: [
          IconButton(
            tooltip: 'Pull',
            icon: const Icon(Icons.download),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PullSheet())),
          ),
          IconButton(
            tooltip: 'Prune',
            icon: const Icon(Icons.cleaning_services),
            onPressed: () => _prune(context, ref),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(imagesProvider)),
        ],
      ),
      body: images.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.layers, title: 'No images', message: 'Pull an image to get started.')
            : ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final img = list[i];
            final name = _name(img.repoTags, img.id);
            final shortId = img.id.length > 19 ? img.id.substring(7, 19) : img.id;
            return Card(
              child: ListTile(
                leading: const LeadingAvatar(icon: Icons.layers),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: MonoText(shortId, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                trailing: MetaChip('${(img.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ImageDetailScreen(imageId: img.id, title: name)),
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
    final danglingOnly = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prune images'),
        content: const Text('Remove dangling images only, or all unused?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('All unused')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Dangling')),
        ],
      ),
    );
    if (danglingOnly == null) return;
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    try {
      await client.pruneImages(danglingOnly: danglingOnly);
      ref.invalidate(imagesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
