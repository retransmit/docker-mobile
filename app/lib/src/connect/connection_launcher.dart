import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session/session_state.dart';
import '../session/transport_factory.dart';
import '../state/providers.dart';
import '../storage/profile_store.dart';
import '../ui/home_screen.dart';

/// Connects the session to [profile] and opens Home on success. The only
/// place the SSH host-key TOFU dialog lives.
Future<void> launchConnection(BuildContext context, WidgetRef ref, ConnectionProfile profile,
    {String? pinOverride}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final session = ref.read(sessionProvider.notifier);
  try {
    await session.connect(profile, pinOverride: pinOverride);
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
  if (!context.mounted) return;
  final s = ref.read(sessionProvider);
  if (s.status == SessionStatus.connected) {
    navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  } else if (s.error != null) {
    messenger.showSnackBar(SnackBar(content: Text('Connection failed: ${s.error!.message}')));
  }
}
