// ignore_for_file: prefer_initializing_formals
import 'transport.dart';

/// Wraps a raw duplex (a hijacked socket or an SSH dial-stdio channel) as an
/// [ExecChannel]. Shared by the TLS and SSH transports.
class SocketExecChannel implements ExecChannel {
  final Stream<List<int>> _input;
  final void Function(List<int>) _onSend;
  final Future<void> Function() _onClose;
  bool _closed = false;

  SocketExecChannel({
    required Stream<List<int>> input,
    required void Function(List<int>) onSend,
    required Future<void> Function() onClose,
  })  : _input = input,
        _onSend = onSend,
        _onClose = onClose;

  @override
  Stream<List<int>> get output => _input;

  @override
  void send(List<int> data) {
    if (_closed) return;
    _onSend(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }
}
