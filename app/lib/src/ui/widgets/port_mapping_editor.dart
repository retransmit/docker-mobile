import 'package:flutter/material.dart';

import '../../api/models/container_create_config.dart';

class PortMappingEditor extends StatefulWidget {
  final void Function(List<PortMapping>) onChanged;
  const PortMappingEditor({super.key, required this.onChanged});

  @override
  State<PortMappingEditor> createState() => _PortMappingEditorState();
}

class _PortRow {
  final TextEditingController host = TextEditingController();
  final TextEditingController container = TextEditingController();
  String proto = 'tcp';
  void dispose() {
    host.dispose();
    container.dispose();
  }
}

class _PortMappingEditorState extends State<PortMappingEditor> {
  final List<_PortRow> _rows = [];

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final list = <PortMapping>[];
    for (final r in _rows) {
      final cp = r.container.text.trim();
      if (cp.isNotEmpty) {
        list.add(PortMapping(containerPort: cp, protocol: r.proto, hostPort: r.host.text.trim()));
      }
    }
    widget.onChanged(list);
  }

  void _add() => setState(() => _rows.add(_PortRow()));
  void _remove(int i) {
    setState(() => _rows.removeAt(i).dispose());
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Ports', style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Add port', onPressed: _add),
        ]),
        for (var i = 0; i < _rows.length; i++)
          Row(children: [
            Expanded(child: TextField(
              controller: _rows[i].host,
              decoration: const InputDecoration(hintText: 'host', isDense: true),
              keyboardType: TextInputType.number,
              onChanged: (_) => _emit(),
            )),
            const SizedBox(width: 8),
            Expanded(child: TextField(
              controller: _rows[i].container,
              decoration: const InputDecoration(hintText: 'container', isDense: true),
              keyboardType: TextInputType.number,
              onChanged: (_) => _emit(),
            )),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: _rows[i].proto,
              items: const [
                DropdownMenuItem(value: 'tcp', child: Text('tcp')),
                DropdownMenuItem(value: 'udp', child: Text('udp')),
              ],
              onChanged: (v) {
                setState(() => _rows[i].proto = v ?? 'tcp');
                _emit();
              },
            ),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Remove',
              onPressed: () => _remove(i),
            ),
          ]),
      ],
    );
  }
}
