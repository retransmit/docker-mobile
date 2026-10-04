import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Returns to the Connections list, then tears the session down: pop first
/// (disposing the screens that watch the connection), then disconnect.
Future<void> disconnect(BuildContext context, WidgetRef ref) async {
  final navigator = Navigator.of(context);
  final session = ref.read(sessionProvider.notifier);
  navigator.popUntil((r) => r.isFirst);
  await session.disconnect();
}
