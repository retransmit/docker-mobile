import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session/transport_factory.dart';
import '../state/providers.dart';
import '../storage/profile_store.dart';
import '../ui/home_screen.dart';

/// Connects the session to [profile] and opens Home when this very attempt
/// connected; one that failed or was cancelled opens nothing, whatever the
/// session is doing by then. The only place the SSH host-key TOFU dialog
/// lives. A failed connect stays in the session state, which the
/// Connections screen shows inline.
///
/// The session lasts as long as Home does: once Home is closed, by the back
/// button or by a Disconnect action, the session is disconnected, and only
/// then does the returned future complete.
Future<void> launchConnection(BuildContext context, WidgetRef ref, ConnectionProfile profile,
    {String? pinOverride}) async {
  final navigator = Navigator.of(context);
  final session = ref.read(sessionProvider.notifier);
  final bool connected;
  try {
    connected = await session.connect(profile, pinOverride: pinOverride);
  } on HostKeyMismatchException catch (e) {
    if (!context.mounted) return;
    final trust = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Host key changed'),
        content: const Text(
            'The server host key does not match the pinned key. This could be a man-in-the-middle attack. Trust the new key only if you expected this change.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Trust new key')),
        ],
      ),
    );
    if (trust == true && context.mounted) {
      await launchConnection(context, ref, profile, pinOverride: e.presentedFingerprint);
    }
    return;
  }
  if (connected && context.mounted) {
    await navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    // Home is gone, however it was left: nothing can show this session any more.
    await session.disconnect();
  }
}
