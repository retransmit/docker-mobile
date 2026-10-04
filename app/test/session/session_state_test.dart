import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/session_state.dart';

void main() {
  test('starts disconnected, foreground, attempt 0, session 0', () {
    const s = SessionState();
    expect(s.status, SessionStatus.disconnected);
    expect(s.foreground, isTrue);
    expect(s.attempt, 0);
    expect(s.sessionId, 0);
    expect(s.isLive, isFalse);
  });

  test('isLive needs connected and foreground', () {
    const s = SessionState(status: SessionStatus.connected);
    expect(s.isLive, isTrue);
    expect(s.copyWith(foreground: false).isLive, isFalse);
    expect(s.copyWith(status: SessionStatus.reconnecting).isLive, isFalse);
  });

  test('copyWith keeps fields unless told, and clears error and warning on request', () {
    const err = DockerError(DockerErrorKind.network, 'down');
    final s = const SessionState().copyWith(error: err, warning: 'old', attempt: 2, apiVersion: '1.45', sessionId: 3);
    expect(s.error, same(err));
    expect(s.copyWith(attempt: 3).error, same(err));
    expect(s.copyWith(clearError: true).error, isNull);
    expect(s.copyWith(clearWarning: true).warning, isNull);
    expect(s.copyWith().apiVersion, '1.45');
    expect(s.copyWith().sessionId, 3);
  });
}
