import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/pull_event.dart';

void main() {
  test('parses a progress event', () {
    final e = PullEvent.fromJson({
      'status': 'Downloading',
      'id': 'abc',
      'progressDetail': {'current': 100, 'total': 500},
    });
    expect(e.status, 'Downloading');
    expect(e.id, 'abc');
    expect(e.current, 100);
    expect(e.total, 500);
    expect(e.error, isNull);
  });

  test('parses an error event', () {
    final e = PullEvent.fromJson({'error': 'manifest unknown', 'errorDetail': {'message': 'manifest unknown'}});
    expect(e.error, 'manifest unknown');
  });

  test('tolerates an event with only status', () {
    final e = PullEvent.fromJson({'status': 'Pull complete', 'id': 'abc'});
    expect(e.current, isNull);
    expect(e.total, isNull);
  });
}
