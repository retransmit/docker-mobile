import 'dart:async';

import 'package:flutter/widgets.dart';

/// App foreground/background changes, abstracted so the session can be
/// tested without a widget binding.
abstract class LifecycleSource {
  Stream<AppLifecycleState> get changes;
}

/// Real source backed by [AppLifecycleListener]. The listener is attached on
/// the first subscription and detached when the last one cancels, so merely
/// constructing this object never touches the binding.
class AppLifecycleSource implements LifecycleSource {
  AppLifecycleListener? _listener;
  late final StreamController<AppLifecycleState> _controller = StreamController<AppLifecycleState>.broadcast(
    sync: true,
    onListen: () => _listener = AppLifecycleListener(onStateChange: _controller.add),
    onCancel: () {
      _listener?.dispose();
      _listener = null;
    },
  );

  @override
  Stream<AppLifecycleState> get changes => _controller.stream;
}
