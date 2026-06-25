import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/ssh/host_key.dart';

void main() {
  test('fingerprint is deterministic, padding-free, and input-sensitive', () {
    final a = fingerprintSha256([1, 2, 3]);
    expect(fingerprintSha256([1, 2, 3]), a); // stable
    expect(fingerprintSha256([1, 2, 4]), isNot(a)); // differs by input
    expect(a.contains('='), isFalse); // no base64 padding
  });

  test('verifyHostKey verdicts', () {
    expect(verifyHostKey(null, 'x'), HostKeyVerdict.firstUse);
    expect(verifyHostKey('x', 'x'), HostKeyVerdict.match);
    expect(verifyHostKey('x', 'y'), HostKeyVerdict.mismatch);
  });
}
