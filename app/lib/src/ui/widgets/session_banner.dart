import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/disconnect.dart';
import '../../session/session_state.dart';
import '../../state/providers.dart';

/// Shows the session's reconnect progress or failure; nothing otherwise.
class SessionBanner extends ConsumerWidget {
  const SessionBanner({super.key, this.navigatorKey});

  /// The app's navigator when the banner sits above it (see
  /// [SessionBannerHost]); otherwise the nearest navigator is used.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Whether the banner shows anything for [status].
  static bool showsFor(SessionStatus status) => status == SessionStatus.reconnecting || status == SessionStatus.failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (status, attempt, error) = ref.watch(sessionProvider.select((s) => (s.status, s.attempt, s.error)));
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case SessionStatus.reconnecting:
        final max = ref.watch(reconnectPolicyProvider).maxAttempts;
        return Material(
          color: scheme.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Reconnecting... (attempt $attempt of $max)',
                      style: TextStyle(color: scheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case SessionStatus.failed:
        return Material(
          color: scheme.errorContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, color: scheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      error?.message ?? 'Connection lost',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref.read(sessionProvider.notifier).retry(),
                    child: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: () => disconnect(context, ref, navigator: navigatorKey?.currentState),
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),
          ),
        );
      case SessionStatus.disconnected:
      case SessionStatus.connecting:
      case SessionStatus.connected:
        return const SizedBox.shrink();
    }
  }
}

/// Puts the [SessionBanner] above every route, so a lost connection shows
/// (and can be retried) on whatever screen the user is on.
class SessionBannerHost extends ConsumerWidget {
  const SessionBannerHost({super.key, required this.navigatorKey, required this.child});

  /// The app's navigator, which is [child].
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(sessionProvider.select((s) => SessionBanner.showsFor(s.status)));
    return Column(
      children: [
        SessionBanner(navigatorKey: navigatorKey),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: visible, // the banner already sits under the status bar
            child: child,
          ),
        ),
      ],
    );
  }
}
