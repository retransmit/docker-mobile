import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/api_version.dart';

void main() {
  test('compares numerically, not lexically', () {
    expect(compareApiVersions('1.10', '1.9'), greaterThan(0));
    expect(compareApiVersions('1.45', '1.45'), 0);
    expect(compareApiVersions('1.4', '1.10'), lessThan(0));
    expect(compareApiVersions('2.0', '1.99'), greaterThan(0));
  });

  test('normalize strips a leading v and whitespace', () {
    expect(normalizeApiVersion(' v1.45 '), '1.45');
    expect(normalizeApiVersion('1.45'), '1.45');
  });

  test('negotiate picks the smaller of daemon and client', () {
    expect(negotiateApiVersion('1.47'), '1.45');
    expect(negotiateApiVersion('1.43'), '1.43');
    expect(negotiateApiVersion('1.45'), '1.45');
    expect(negotiateApiVersion('v1.43'), '1.43');
    expect(negotiateApiVersion('1.47', client: '1.40'), '1.40');
  });

  test('negotiate falls back to the client version when the daemon reports nothing', () {
    expect(negotiateApiVersion(''), kClientApiVersion);
    expect(negotiateApiVersion('garbage'), kClientApiVersion);
  });

  test('isBelowMinSupported', () {
    expect(isBelowMinSupported('1.40'), isTrue);
    expect(isBelowMinSupported('1.41'), isFalse);
    expect(isBelowMinSupported('1.45'), isFalse);
  });
}
