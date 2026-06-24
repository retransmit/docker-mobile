import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class ImageDetailScreen extends ConsumerWidget {
  final String imageId;
  final String title;
  const ImageDetailScreen({super.key, required this.imageId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(imageDetailProvider(imageId));
    final history = ref.watch(imageHistoryProvider(imageId));
    final client = ref.read(dockerClientProvider);
    final messenger = ScaffoldMessenger.of(context);

    Future<void> run(Future<void> Function() action, String ok) async {
      try {
        await action();
        messenger.showSnackBar(SnackBar(content: Text(ok)));
        ref.invalidate(imagesProvider);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${d.architecture}/${d.os}  ·  ${(d.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
            const SizedBox(height: 4),
            Text('Created: ${d.created}'),
            if (d.exposedPorts.isNotEmpty) Text('Exposed: ${d.exposedPorts.join(', ')}'),
            if (d.env.isNotEmpty) Text('Env: ${d.env.join('\n')}'),
            const Divider(height: 24),
            Wrap(spacing: 8, children: [
              OutlinedButton(
                onPressed: () async {
                  final t = await _tagDialog(context);
                  if (t != null && client != null && context.mounted) {
                    await run(() => client.tagImage(imageId, repo: t.$1, tag: t.$2), 'Tagged');
                  }
                },
                child: const Text('Tag'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final opts = await _removeImageDialog(context);
                  if (opts != null && client != null && context.mounted) {
                    await run(() => client.removeImage(imageId, force: opts.$1, noprune: opts.$2), 'Removed');
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
                child: const Text('Remove'),
              ),
            ]),
            const Divider(height: 24),
            const Text('History', style: TextStyle(fontWeight: FontWeight.bold)),
            ...history.maybeWhen(
              data: (layers) => layers.map((l) => ListTile(
                    dense: true,
                    title: Text(l.createdBy, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text('${(l.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
                  )),
              orElse: () => [const ListTile(dense: true, title: Text('Loading history…'))],
            ),
          ],
        ),
      ),
    );
  }
}

Future<(String, String)?> _tagDialog(BuildContext context) async {
  final repo = TextEditingController();
  final tag = TextEditingController(text: 'latest');
  try {
    return await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tag image'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: repo, decoration: const InputDecoration(labelText: 'Repository')),
          TextField(controller: tag, decoration: const InputDecoration(labelText: 'Tag')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (repo.text, tag.text)), child: const Text('Tag')),
        ],
      ),
    );
  } finally {
    repo.dispose();
    tag.dispose();
  }
}

Future<(bool, bool)?> _removeImageDialog(BuildContext context) {
  var force = false;
  var noprune = false;
  return showDialog<(bool, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove image?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(title: const Text('Force'), value: force, onChanged: (v) => setState(() => force = v)),
          SwitchListTile(title: const Text('No prune'), value: noprune, onChanged: (v) => setState(() => noprune = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (force, noprune)), child: const Text('Remove')),
        ],
      ),
    ),
  );
}
