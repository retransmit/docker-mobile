import 'package:flutter/material.dart';

class KeyValueEditor extends StatefulWidget {
  final String title;
  final void Function(Map<String, String>) onChanged;
  const KeyValueEditor({super.key, required this.title, required this.onChanged});

  @override
  State<KeyValueEditor> createState() => _KeyValueEditorState();
}

class _KvRow {
  final TextEditingController key = TextEditingController();
  final TextEditingController value = TextEditingController();
  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _KeyValueEditorState extends State<KeyValueEditor> {
  final List<_KvRow> _rows = [];

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final map = <String, String>{};
    for (final r in _rows) {
      final k = r.key.text.trim();
      if (k.isNotEmpty) map[k] = r.value.text;
    }
    widget.onChanged(map);
  }

  void _add() => setState(() => _rows.add(_KvRow()));

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
          Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Add', onPressed: _add),
        ]),
        for (var i = 0; i < _rows.length; i++)
          Row(children: [
            Expanded(child: TextField(
              controller: _rows[i].key,
              decoration: const InputDecoration(hintText: 'key', isDense: true),
              onChanged: (_) => _emit(),
            )),
            const SizedBox(width: 8),
            Expanded(child: TextField(
              controller: _rows[i].value,
              decoration: const InputDecoration(hintText: 'value', isDense: true),
              onChanged: (_) => _emit(),
            )),
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
