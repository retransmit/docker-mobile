import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/pull_event.dart';
import '../state/providers.dart';

/// Splits an image ref into (image, tag); a colon after the last slash is the tag.
(String, String) parseImageRef(String ref) {
  final slash = ref.lastIndexOf('/');
  final colon = ref.lastIndexOf(':');
  if (colon > slash && colon != -1) {
    return (ref.substring(0, colon), ref.substring(colon + 1));
  }
  return (ref, 'latest');
}

class PullSheet extends ConsumerStatefulWidget {
  const PullSheet({super.key});

  @override
  ConsumerState<PullSheet> createState() => _PullSheetState();
}

class _PullSheetState extends ConsumerState<PullSheet> {
  final _ref = TextEditingController();
  StreamSubscription<PullEvent>? _sub;
  final Map<String, PullEvent> _layers = {};
  String _overall = '';
  String? _error;
  bool _running = false;
  bool _done = false;

  @override
  void dispose() {
    _sub?.cancel();
    _ref.dispose();
    super.dispose();
  }

  void _pull() {
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final (image, tag) = parseImageRef(_ref.text.trim());
    setState(() {
      _layers.clear();
      _overall = 'Pulling $image:$tag…';
      _error = null;
      _running = true;
      _done = false;
    });
    _sub?.cancel();
    _sub = client.pullImage(image, tag: tag).listen((e) {
      setState(() {
        if (e.error != null) {
          _error = e.error;
        } else if (e.id != null && e.id!.isNotEmpty) {
          _layers[e.id!] = e;
        } else {
          _overall = e.status;
        }
      });
    }, onError: (e) {
      setState(() {
        _error = '$e';
        _running = false;
      });
    }, onDone: () {
      setState(() {
        _running = false;
        _done = true;
      });
      if (_error == null) ref.invalidate(imagesProvider); // surface the new image on return
    });
  }

  @override
  Widget build(BuildContext context) {
    final layers = _layers.values.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Pull image')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: TextField(
                controller: _ref,
                decoration: const InputDecoration(labelText: 'Image (e.g. nginx:latest)'),
              )),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _running ? null : _pull, child: const Text('Pull')),
            ]),
            const SizedBox(height: 12),
            if (_overall.isNotEmpty) Text(_overall, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Error: $_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_done && _error == null)
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('Pull complete')),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: layers.length,
                itemBuilder: (context, i) {
                  final l = layers[i];
                  final progress = (l.total != null && l.total! > 0 && l.current != null)
                      ? (l.current! / l.total!).clamp(0.0, 1.0)
                      : null;
                  return ListTile(
                    dense: true,
                    title: Text('${l.id}: ${l.status}'),
                    subtitle: progress == null ? null : LinearProgressIndicator(value: progress),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
