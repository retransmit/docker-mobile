import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'widgets/key_value_editor.dart';

class VolumeCreateSheet extends ConsumerStatefulWidget {
  const VolumeCreateSheet({super.key});

  @override
  ConsumerState<VolumeCreateSheet> createState() => _VolumeCreateSheetState();
}

class _VolumeCreateSheetState extends ConsumerState<VolumeCreateSheet> {
  final _name = TextEditingController();
  final _driver = TextEditingController(text: 'local');
  Map<String, String> _labels = {};
  Map<String, String> _opts = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _driver.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await client.createVolume(
        name: _name.text.trim(),
        driver: _driver.text.trim().isEmpty ? 'local' : _driver.text.trim(),
        labels: _labels,
        driverOpts: _opts,
      );
      ref.invalidate(volumesProvider);
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Volume created')));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = !_busy && _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Create volume')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: _driver, decoration: const InputDecoration(labelText: 'Driver')),
          const Divider(),
          KeyValueEditor(title: 'Labels', onChanged: (m) => _labels = m),
          const Divider(),
          KeyValueEditor(title: 'Driver options', onChanged: (m) => _opts = m),
          const SizedBox(height: 16),
          FilledButton(onPressed: canCreate ? _create : null, child: const Text('Create')),
        ],
      ),
    );
  }
}
