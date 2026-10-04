import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connection_launcher.dart';
import '../session/session_state.dart';
import '../state/providers.dart';
import '../storage/profile_store.dart';
import 'connection_screen.dart';
import 'settings_screen.dart';
import 'widgets/error_view.dart';
import 'widgets/resource_widgets.dart';
import 'widgets/skeletons.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  IconData _icon(ConnectionKind k) => switch (k) {
        ConnectionKind.agent => Icons.dns,
        ConnectionKind.tls => Icons.lock,
        ConnectionKind.ssh => Icons.terminal,
      };

  /// Opens the editor. "Save & Connect" there returns the saved profile; the
  /// connect runs here so its progress and any error show on the list.
  Future<void> _openEditor(BuildContext context, WidgetRef ref, {ConnectionProfile? editing}) async {
    final saved = await Navigator.of(context).push<ConnectionProfile>(
      MaterialPageRoute(builder: (_) => ConnectionScreen(editing: editing)),
    );
    if (saved != null && context.mounted) await launchConnection(context, ref, saved);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final (status, sessionProfileId, sessionProfileName, sessionError) =
        ref.watch(sessionProvider.select((s) => (s.status, s.profile?.id, s.profile?.name, s.error)));
    // While a connect is in flight the screen is busy: nothing on it reacts but Settings and
    // the Cancel in the bar at the bottom.
    final connecting = status == SessionStatus.connecting;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      // Not shown while connecting: a FAB with a null handler looks enabled.
      floatingActionButton: connecting
          ? null
          : FloatingActionButton(
              // No hero: when a connect succeeds, this button comes back in the frame that pushes
              // Home, while the Scaffold still animates the previous one out. Two heroes with one
              // tag in the route being left is an error.
              heroTag: null,
              onPressed: () => _openEditor(context, ref),
              child: const Icon(Icons.add),
            ),
      bottomNavigationBar: connecting
          ? Material(
              elevation: 3,
              color: scheme.surfaceContainerHigh,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Connecting to ${sessionProfileName ?? 'the daemon'}...',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => ref.read(sessionProvider.notifier).disconnect(),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: profiles.when(
          loading: () => const SkeletonList(key: ValueKey('loading')),
          error: (e, _) => ErrorView(key: const ValueKey('error'), error: e, onRetry: () => ref.invalidate(profilesProvider), busy: profiles.isRefreshing),
          data: (list) => KeyedSubtree(
            key: const ValueKey('data'),
            child: list.isEmpty
              ? EmptyState(
                icon: Icons.dns,
                title: 'No connections',
                message: 'Add a Docker host to get started.',
                action: FilledButton.icon(
                  onPressed: connecting ? null : () => _openEditor(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add connection'),
                ),
              )
            : ListView(
                children: [
                  for (final p in list)
                    Card(
                      child: ListTile(
                        leading: connecting && sessionProfileId == p.id
                            ? const SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                                ),
                              )
                            : LeadingAvatar(icon: _icon(p.kind)),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                MetaChip(p.kind.name),
                                const SizedBox(width: 8),
                                Expanded(child: MonoText(p.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
                              ],
                            ),
                            if (status == SessionStatus.disconnected && sessionError != null && sessionProfileId == p.id)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  sessionError.message,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error),
                                ),
                              ),
                          ],
                        ),
                        onTap: connecting ? null : () { HapticFeedback.lightImpact(); launchConnection(context, ref, p); },
                        trailing: PopupMenuButton<String>(
                          enabled: !connecting,
                          onSelected: (v) async {
                            if (v == 'edit') {
                              await _openEditor(context, ref, editing: p);
                            } else if (v == 'delete') {
                              await ref.read(profileStoreProvider).delete(p.id);
                              ref.invalidate(profilesProvider);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
          ),
        ),
      ),
    );
  }
}
