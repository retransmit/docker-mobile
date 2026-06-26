import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/duplex_exec_channel.dart';

void main() {
  test('forwards send, maps output, closes once', () async {
    final sent = <List<int>>[];
    var closes = 0;
    final ch = SocketExecChannel(
      input: Stream.value(utf8.encode('out')),
      onSend: sent.add,
      onClose: () async => closes++,
    );
    expect(utf8.decode(await ch.output.first), 'out');
    ch.send(utf8.encode('in'));
    expect(utf8.decode(sent.single), 'in');
    await ch.close();
    await ch.close(); // idempotent
    ch.send(utf8.encode('after')); // no-op after close
    expect(closes, 1);
    expect(sent.length, 1);
  });
}
