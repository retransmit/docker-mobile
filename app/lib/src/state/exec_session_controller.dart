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
  String command; // empty => default bash/sh chooser

  /// Bumped by every start, restart and end; a handshake that finishes under
  /// an older generation closes its channel and changes nothing.
  int _generation = 0;

  ExecSessionController(this.client, this.containerId, {this.command = ''}) {
    terminal.onOutput = (data) => _channel?.send(utf8.encode(data));
    terminal.onResize = (w, h, pw, ph) {
      final id = _execId;
      if (id != null) {
        client.resizeExec(id, cols: w, rows: h).ignore();
      }
    };
    _start();
  }

  List<String> get _cmd =>
      command.trim().isEmpty ? _defaultShell : ['/bin/sh', '-c', command];

  Future<void> _start() async {
    final gen = ++_generation;
    status = ExecStatus.connecting;
    exitCode = null;
    _execId = null;
    notifyListeners();
    try {
      final id = await client.createExec(containerId, cmd: _cmd, tty: true);
      if (_disposed || gen != _generation) return;
      final ch = await client.attachExec(id, cols: terminal.viewWidth, rows: terminal.viewHeight);
      // Disposed, ended or restarted while the handshake was in flight: tear
      // down the freshly-resolved channel instead of leaking it, and never
      // notify listeners after super.dispose().
      if (_disposed || gen != _generation) {
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
      if (_disposed || gen != _generation) return;
      status = ExecStatus.error;
      notifyListeners();
    }
  }

  Future<void> _onEnded() async {
    if (_disposed) return;
    final gen = _generation;
    status = ExecStatus.ended;
    notifyListeners(); // show "ended" now; the exit code can lag on a dead connection
    final id = _execId;
    _execId = null;
    if (id == null) return;
    int? code;
    try {
      code = (await client.inspectExec(id)).exitCode;
    } catch (_) {/* leave the exit code unknown */}
    if (_disposed || gen != _generation) return;
    exitCode = code;
    notifyListeners();
  }

  Future<void> restart(String newCommand) async {
    if (_disposed) return;
    command = newCommand;
    _generation++; // a handshake still in flight must not land during the teardown
    final sub = _outputSub;
    _outputSub = null;
    final channel = _channel;
    _channel = null;
    // Neither the cancel nor the close is waited on: both take effect at
    // once, and a close on a dead connection must not hold up the new session.
    unawaited(sub?.cancel());
    unawaited(_closeQuietly(channel));
    await _start();
  }

  static Future<void> _closeQuietly(ExecChannel? channel) async {
    try {
      await channel?.close();
    } catch (_) {
      // best-effort teardown
    }
  }

  /// Ends the session from outside (the connection it ran on is gone): stop
  /// reading and close the channel. The exit code is unknown.
  Future<void> end() async {
    if (_disposed || status == ExecStatus.ended) return;
    _generation++; // discard a handshake still in flight
    final sub = _outputSub;
    _outputSub = null;
    final channel = _channel;
    _channel = null;
    _execId = null;
    status = ExecStatus.ended;
    exitCode = null;
    notifyListeners();
    // The cancel takes effect at once; not awaiting it lets the close start
    // in the same turn, as dispose() does.
    unawaited(sub?.cancel());
    await _closeQuietly(channel);
  }

  @override
  void dispose() {
    _disposed = true;
    _outputSub?.cancel();
    _channel?.close();
    super.dispose();
  }
}
