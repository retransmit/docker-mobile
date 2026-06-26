import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Tears down the active connection and returns to the profiles list:
/// pop first (disposing the home screen + its providers), then detach and
/// close the transport (best-effort).
Future<void> disconnect(BuildContext context, WidgetRef ref) async {
  final navigator = Navigator.of(context);
  final transport = ref.read(transportProvider);
  navigator.popUntil((r) => r.isFirst);
  ref.read(transportProvider.notifier).state = null;
  // Best-effort teardown: the UI is already back at the list, so a close
  // failure must not surface as an unhandled async error.
  try {
    await transport?.close();
  } catch (_) {}
}
