import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/docker_network.dart';
import '../state/providers.dart';
import 'widgets/key_value_editor.dart';

class _SubnetRow {
  final TextEditingController subnet = TextEditingController();
  final TextEditingController gateway = TextEditingController();
  final TextEditingController ipRange = TextEditingController();
  void dispose() {
    subnet.dispose();
    gateway.dispose();
    ipRange.dispose();
  }
}

class NetworkCreateSheet extends ConsumerStatefulWidget {
  const NetworkCreateSheet({super.key});

  @override
  ConsumerState<NetworkCreateSheet> createState() => _NetworkCreateSheetState();
}

class _NetworkCreateSheetState extends ConsumerState<NetworkCreateSheet> {
  final _name = TextEditingController();
  String _driver = 'bridge';
  bool _internal = false;
  bool _attachable = false;
  bool _enableIPv6 = false;
  final List<_SubnetRow> _subnets = [];
  Map<String, String> _labels = {};
  Map<String, String> _options = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {})); // toggle Create enabled
  }

  @override
  void dispose() {
    _name.dispose();
    for (final s in _subnets) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await client.createNetwork(
        name: _name.text.trim(),
        driver: _driver,
        internal: _internal,
        attachable: _attachable,
        enableIPv6: _enableIPv6,
        ipam: _subnets
            .map((s) => IpamConfig(subnet: s.subnet.text.trim(), gateway: s.gateway.text.trim(), ipRange: s.ipRange.text.trim()))
            .where((c) => (c.subnet ?? '').isNotEmpty || (c.gateway ?? '').isNotEmpty || (c.ipRange ?? '').isNotEmpty)
            .toList(),
        labels: _labels,
        options: _options,
      );
      ref.invalidate(networksProvider);
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Network created')));
    } catch (e) {
      if (mounted) setState(() => _busy = false); // sheet may be popped mid-flight
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = !_busy && _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Create network')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Driver'),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _driver,
              items: const ['bridge', 'overlay', 'macvlan', 'ipvlan']
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: (v) => setState(() => _driver = v ?? 'bridge'),
            ),
          ]),
          SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('Internal'), value: _internal, onChanged: (v) => setState(() => _internal = v)),
          SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('Attachable'), value: _attachable, onChanged: (v) => setState(() => _attachable = v)),
          SwitchListTile(dense: true, contentPadding: EdgeInsets.zero, title: const Text('Enable IPv6'), value: _enableIPv6, onChanged: (v) => setState(() => _enableIPv6 = v)),
          const Divider(),
          Row(children: [
            const Text('IPAM subnets', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            OutlinedButton(onPressed: () => setState(() => _subnets.add(_SubnetRow())), child: const Text('Add subnet')),
          ]),
          for (var i = 0; i < _subnets.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: TextField(controller: _subnets[i].subnet, decoration: const InputDecoration(labelText: 'Subnet (CIDR)', isDense: true))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _subnets[i].gateway, decoration: const InputDecoration(labelText: 'Gateway', isDense: true))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: _subnets[i].ipRange, decoration: const InputDecoration(labelText: 'IP range', isDense: true))),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: 'Remove subnet',
                      onPressed: () => setState(() => _subnets.removeAt(i).dispose()),
                    ),
                  ],
                ),
              ),
            ),
          const Divider(),
          KeyValueEditor(title: 'Labels', onChanged: (m) => _labels = m),
          const Divider(),
          KeyValueEditor(title: 'Options', onChanged: (m) => _options = m),
          const SizedBox(height: 16),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(onPressed: canCreate ? _create : null, child: const Text('Create')),
      ),
    );
  }
}
