import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../api/models/log_line.dart';
import '../api/stdcopy.dart';
import '../state/logs_notifier.dart';

class LogsScreen extends ConsumerWidget {
  final String containerId;
  final String containerName;
  const LogsScreen({super.key, required this.containerId, required this.containerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inspect = ref.watch(containerInspectProvider(containerId));
    return Scaffold(
      appBar: AppBar(title: Text(containerName)),
      body: inspect.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBanner(
          message: '$e',
          onRetry: () => ref.invalidate(containerInspectProvider(containerId)),
        ),
        data: (info) => _LogsBody(key: ValueKey(info.id), id: containerId, tty: info.tty),
      ),
    );
  }
}

class _LogsBody extends ConsumerStatefulWidget {
  final String id;
  final bool tty;
  const _LogsBody({super.key, required this.id, required this.tty});

  @override
  ConsumerState<_LogsBody> createState() => _LogsBodyState();
}

class _LogsBodyState extends ConsumerState<_LogsBody> {
  final _scroll = ScrollController();
  final _searchCtl = TextEditingController();
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 8;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  void _jumpToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = (id: widget.id, tty: widget.tty);
    final state = ref.watch(logsProvider(key));
    final notifier = ref.read(logsProvider(key).notifier);
    final lines = state.visibleLines;

    // Keep pinned to newest while following and already at the bottom.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.following && _atBottom && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });

    return Stack(
      children: [
        Column(
          children: [
            _Controls(
              state: state,
              searchCtl: _searchCtl,
              onFollow: notifier.setFollowing,
              onTimestamps: notifier.setTimestamps,
              onTail: notifier.setTail,
              onSearch: notifier.setSearch,
              onShare: () => SharePlus.instance.share(ShareParams(text: notifier.snapshot())),
            ),
            if (state.status == LogsStatus.error)
              _ErrorBanner(message: state.error ?? 'stream error', onRetry: notifier.retry),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemCount: lines.length,
                itemBuilder: (context, i) => _LogLineView(
                  line: lines[i],
                  query: state.search,
                  showTimestamp: state.timestamps,
                ),
              ),
            ),
          ],
        ),
        if (!_atBottom)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              onPressed: _jumpToBottom,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }
}

class _LogLineView extends StatelessWidget {
  final LogLine line;
  final String query;
  final bool showTimestamp;
  const _LogLineView({required this.line, required this.query, required this.showTimestamp});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: line.source == LogStream.stderr ? scheme.error : scheme.onSurface,
    );
    final prefix = (showTimestamp && line.timestamp != null)
        ? '${line.timestamp!.toLocal().toIso8601String()} '
        : '';
    final text = '$prefix${line.text}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: SelectableText.rich(
        TextSpan(style: base, children: _highlightSpans(context, text, query, base)),
      ),
    );
  }

  List<TextSpan> _highlightSpans(BuildContext context, String text, String query, TextStyle base) {
    if (query.isEmpty) return [TextSpan(text: text)];
    final hl = base.copyWith(
      backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
      fontWeight: FontWeight.bold,
    );
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    var i = 0;
    while (true) {
      final idx = lower.indexOf(q, i);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(i)));
        break;
      }
      if (idx > i) spans.add(TextSpan(text: text.substring(i, idx)));
      spans.add(TextSpan(text: text.substring(idx, idx + q.length), style: hl));
      i = idx + q.length;
    }
    return spans;
  }
}

class _Controls extends StatelessWidget {
  final LogsState state;
  final TextEditingController searchCtl;
  final ValueChanged<bool> onFollow;
  final ValueChanged<bool> onTimestamps;
  final ValueChanged<int?> onTail;
  final ValueChanged<String> onSearch;
  final VoidCallback onShare;
  const _Controls({
    required this.state,
    required this.searchCtl,
    required this.onFollow,
    required this.onTimestamps,
    required this.onTail,
    required this.onSearch,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Follow',
            icon: Icon(state.following ? Icons.pause : Icons.play_arrow),
            onPressed: () => onFollow(!state.following),
          ),
          IconButton(
            tooltip: 'Timestamps',
            icon: Icon(state.timestamps ? Icons.schedule : Icons.schedule_outlined),
            onPressed: () => onTimestamps(!state.timestamps),
          ),
          PopupMenuButton<int?>(
            tooltip: 'Tail',
            icon: const Icon(Icons.format_list_numbered),
            onSelected: onTail,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 100, child: Text('Tail 100')),
              PopupMenuItem(value: 500, child: Text('Tail 500')),
              PopupMenuItem(value: 1000, child: Text('Tail 1000')),
              PopupMenuItem(value: null, child: Text('All')),
            ],
          ),
          IconButton(tooltip: 'Share', icon: const Icon(Icons.ios_share), onPressed: onShare),
          Expanded(
            child: TextField(
              controller: searchCtl,
              decoration: const InputDecoration(
                hintText: 'Search',
                isDense: true,
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: onSearch,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text(message),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      actions: [TextButton(onPressed: onRetry, child: const Text('Retry'))],
    );
  }
}
