import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/exec_inspect.dart';

void main() {
  test('parses /exec/{id}/json', () {
    final e = ExecInspect.fromJson({'Running': false, 'ExitCode': 137});
    expect(e.running, isFalse);
    expect(e.exitCode, 137);
  });

  test('tolerates a null exit code while running', () {
    final e = ExecInspect.fromJson({'Running': true, 'ExitCode': null});
    expect(e.running, isTrue);
    expect(e.exitCode, isNull);
  });
}
