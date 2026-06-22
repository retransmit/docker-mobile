import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../api/docker_api_client.dart';
import '../transport/transport.dart';

enum ExecStatus { connecting, connected, ended, error }

/// Default command: try bash, fall back to sh, in a single exec.
const _defaultShell = [
  '/bin/sh',
  '-c',
  'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi',
];

class ExecSessionController extends ChangeNotifier {
  final DockerApiClient client;
  final String containerId;
  final Terminal terminal = Terminal(maxLines: 10000);

  ExecChannel? _channel;
  StreamSubscription<List<int>>? _outputSub;
  String? _execId;
  bool _disposed = false;
  ExecStatus status = ExecStatus.connecting;
  int? exitCode;
  String command = ''; // empty => default bash/sh chooser

  ExecSessionController(this.client, this.containerId) {
    terminal.onOutput = (data) => _channel?.send(utf8.encode(data));
    terminal.onResize = (w, h, pw, ph) {
      final id = _execId;
      if (id != null) {
        client.resizeExec(id, cols: w, rows: h);
      }
    };
    _start();
  }

  List<String> get _cmd =>
      command.trim().isEmpty ? _defaultShell : ['/bin/sh', '-c', command];

  Future<void> _start() async {
    status = ExecStatus.connecting;
    exitCode = null;
    _execId = null;
    notifyListeners();
    try {
      final id = await client.createExec(containerId, cmd: _cmd, tty: true);
      final ch = await client.attachExec(id, cols: terminal.viewWidth, rows: terminal.viewHeight);
      // If we were disposed while the handshake was in flight, tear down the
      // freshly-resolved channel instead of leaking the hijacked agent conn,
      // and never notify listeners after super.dispose().
      if (_disposed) {
        unawaited(ch.close());
        return;
      }
      _execId = id;
      _channel = ch;
      status = ExecStatus.connected;
      notifyListeners();
      _outputSub = ch.output.listen(
        (bytes) => terminal.write(utf8.decode(bytes, allowMalformed: true)),
        onDone: _onEnded,
        onError: (_) => _onEnded(),
      );
    } catch (_) {
      if (_disposed) return;
      status = ExecStatus.error;
      notifyListeners();
    }
  }

  Future<void> _onEnded() async {
    if (_disposed) return;
    status = ExecStatus.ended;
    final id = _execId;
    if (id != null) {
      try {
        exitCode = (await client.inspectExec(id)).exitCode;
      } catch (_) {/* leave exitCode null */}
    }
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> restart(String newCommand) async {
    command = newCommand;
    await _outputSub?.cancel();
    await _channel?.close();
    await _start();
  }

  @override
  void dispose() {
    _disposed = true;
    _outputSub?.cancel();
    _channel?.close();
    super.dispose();
  }
}
