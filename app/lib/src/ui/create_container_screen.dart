import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_create_config.dart';
import '../api/models/pull_event.dart';
import '../state/providers.dart';
import 'pull_sheet.dart' show parseImageRef;
import 'widgets/key_value_editor.dart';
import 'widgets/port_mapping_editor.dart';

class CreateContainerScreen extends ConsumerStatefulWidget {
  final String? image;
  const CreateContainerScreen({super.key, this.image});

  @override
  ConsumerState<CreateContainerScreen> createState() => _CreateContainerScreenState();
}

class _CreateContainerScreenState extends ConsumerState<CreateContainerScreen> {
  final _image = TextEditingController();
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _memory = TextEditingController();
  final _cpus = TextEditingController();
  Map<String, String> _env = {};
  Map<String, String> _labels = {};
  Map<String, String> _binds = {};
  List<PortMapping> _ports = [];
  String? _restart;
  String? _network;
  bool _start = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.image != null) _image.text = widget.image!;
  }

  @override
  void dispose() {
    _image.dispose();
    _name.dispose();
    _command.dispose();
    _memory.dispose();
    _cpus.dispose();
    super.dispose();
  }

  int? _memBytes() {
    final mb = int.tryParse(_memory.text.trim());
    return mb == null ? null : mb * 1024 * 1024;
  }

  ContainerCreateConfig _buildConfig(String image) => ContainerCreateConfig(
        image: image,
        cmd: ContainerCreateConfig.parseCommand(_command.text),
        env: _env,
        ports: _ports,
        binds: _binds,
        restartPolicy: _restart,
        labels: _labels,
        network: _network,
        memoryBytes: _memBytes(),
        cpus: double.tryParse(_cpus.text.trim()),
      );

  Future<void> _create() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final image = _image.text.trim();
    if (image.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Image is required.')));
      return;
    }
    final config = _buildConfig(image);
    final name = _name.text.trim();

    setState(() => _busy = true);
    try {
      String id;
      try {
        id = await client.createContainer(config, name: name.isEmpty ? null : name);
      } on DockerApiException catch (e) {
        if (e.statusCode != 404 && !e.body.contains('No such image')) rethrow;
        if (!mounted) return;
        final pull = await _confirmPull(image);
        if (pull != true) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        if (!mounted) return;
        final ok = await _pullImage(image);
        if (!ok) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        id = await client.createContainer(config, name: name.isEmpty ? null : name);
      }
      if (_start) await client.startContainer(id);
      ref.invalidate(containersProvider);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Container created.')));
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<bool?> _confirmPull(String image) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Image not found'),
          content: Text('"$image" is not present locally. Pull it and retry?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pull')),
          ],
        ),
      );

  Future<bool> _pullImage(String image) async {
    final client = ref.read(dockerClientProvider);
    if (client == null) return false;
    final (img, tag) = parseImageRef(image);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PullProgressDialog(stream: client.pullImage(img, tag: tag)),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final networks = ref.watch(networksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Create container')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _image, decoration: const InputDecoration(labelText: 'Image (e.g. nginx:latest)')),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)')),
          TextField(controller: _command, decoration: const InputDecoration(labelText: 'Command (optional, space-separated)')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _network,
            decoration: const InputDecoration(labelText: 'Network'),
            items: [
              const DropdownMenuItem(value: null, child: Text('(default)')),
              ...networks.maybeWhen(
                data: (list) => list.map((n) => DropdownMenuItem<String?>(value: n.name, child: Text(n.name))),
                orElse: () => const <DropdownMenuItem<String?>>[],
              ),
            ],
            onChanged: (v) => setState(() => _network = v),
          ),
          DropdownButtonFormField<String?>(
            initialValue: _restart,
            decoration: const InputDecoration(labelText: 'Restart policy'),
            items: const [
              DropdownMenuItem(value: null, child: Text('(none)')),
              DropdownMenuItem(value: 'no', child: Text('no')),
              DropdownMenuItem(value: 'on-failure', child: Text('on-failure')),
              DropdownMenuItem(value: 'always', child: Text('always')),
              DropdownMenuItem(value: 'unless-stopped', child: Text('unless-stopped')),
            ],
            onChanged: (v) => setState(() => _restart = v),
          ),
          Row(children: [
            Expanded(child: TextField(controller: _memory, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Memory (MB)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _cpus, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'CPUs'))),
          ]),
          const SizedBox(height: 12),
          KeyValueEditor(title: 'Environment', onChanged: (m) => _env = m),
          const SizedBox(height: 12),
          PortMappingEditor(onChanged: (p) => _ports = p),
          const SizedBox(height: 12),
          KeyValueEditor(title: 'Volumes (host → container)', onChanged: (m) => _binds = m),
          const SizedBox(height: 12),
          KeyValueEditor(title: 'Labels', onChanged: (m) => _labels = m),
          const SizedBox(height: 12),
          SwitchListTile(title: const Text('Start after create'), value: _start, onChanged: (v) => setState(() => _start = v)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(onPressed: _busy ? null : _create, child: const Text('Create')),
        ),
      ),
    );
  }
}

class _PullProgressDialog extends StatefulWidget {
  final Stream<PullEvent> stream;
  const _PullProgressDialog({required this.stream});
  @override
  State<_PullProgressDialog> createState() => _PullProgressDialogState();
}

class _PullProgressDialogState extends State<_PullProgressDialog> {
  StreamSubscription<PullEvent>? _sub;
  String _status = 'Pulling…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(
      (e) => setState(() {
        if (e.error != null) {
          _error = e.error;
        } else {
          _status = e.status;
        }
      }),
      onError: (Object e) {
        if (mounted) Navigator.of(context).pop(false);
      },
      onDone: () {
        if (mounted) Navigator.of(context).pop(_error == null);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pulling image'),
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: Text(_error ?? _status)),
        ]),
      );
}
