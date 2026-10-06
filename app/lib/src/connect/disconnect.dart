import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Returns to the Connections list, then tears the session down: pop first
/// (disposing the screens that watch the connection), then disconnect.
/// Pass [navigator] when [context] sits above the app's navigator.
Future<void> disconnect(BuildContext context, WidgetRef ref, {NavigatorState? navigator}) async {
  final nav = navigator ?? Navigator.of(context);
  final session = ref.read(sessionProvider.notifier);
  nav.popUntil((r) => r.isFirst);
  await session.disconnect();
}
