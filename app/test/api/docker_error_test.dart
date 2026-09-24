import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';

void main() {
  group('fromResponse', () {
    test('maps status families to kinds', () {
      expect(DockerError.fromResponse(401, '').kind, DockerErrorKind.unauthorized);
      expect(DockerError.fromResponse(403, '').kind, DockerErrorKind.unauthorized);
      expect(DockerError.fromResponse(404, '').kind, DockerErrorKind.notFound);
      expect(DockerError.fromResponse(409, '').kind, DockerErrorKind.conflict);
      expect(DockerError.fromResponse(400, '').kind, DockerErrorKind.badRequest);
      expect(DockerError.fromResponse(500, '').kind, DockerErrorKind.server);
      expect(DockerError.fromResponse(503, '').kind, DockerErrorKind.server);
      expect(DockerError.fromResponse(418, '').kind, DockerErrorKind.unknown);
      expect(DockerError.fromResponse(404, '').statusCode, 404);
    });

    test('parses the daemon JSON message', () {
      final e = DockerError.fromResponse(404, '{"message":"No such container: web"}');
      expect(e.message, 'No such container: web');
      expect(e.toString(), 'No such container: web');
    });

    test('plain text body becomes the message, clipped to 200 chars', () {
      expect(DockerError.fromResponse(500, '  boom  ').message, 'boom');
      final long = 'x' * 500;
      expect(DockerError.fromResponse(500, long).message.length, 203); // 200 + '...'
    });

    test('empty body falls back to the label', () {
      expect(DockerError.fromResponse(500, '').message, 'Daemon error (HTTP 500)');
      expect(DockerError.fromResponse(401, '').message, 'Unauthorized - check the token or certificate');
      expect(DockerError.fromResponse(404, '   ').message, 'Not found');
    });

    test('html body falls back to the label', () {
      const html = '<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>';
      expect(DockerError.fromResponse(502, html).message, 'Daemon error (HTTP 502)');
    });

    test('JSON without a message field falls back to the raw text', () {
      expect(DockerError.fromResponse(500, '{"error":"x"}').message, '{"error":"x"}');
    });
  });

  group('fromException', () {
    test('timeout', () {
      final e = DockerError.fromException(TimeoutException('t'));
      expect(e.kind, DockerErrorKind.timeout);
      expect(e.retryable, isTrue);
    });

    test('socket errors are network and keep the OS detail', () {
      final e = DockerError.fromException(
          const SocketException('Connection refused', osError: OSError('Connection refused', 111)));
      expect(e.kind, DockerErrorKind.network);
      expect(e.message, contains('Connection refused'));
      expect(e.retryable, isTrue);
    });

    test('tls handshake and websocket errors are network', () {
      expect(DockerError.fromException(const HandshakeException('bad cert')).kind, DockerErrorKind.network);
      expect(DockerError.fromException(const WebSocketException('closed')).kind, DockerErrorKind.network);
    });

    test('anything else is unknown with its text', () {
      final e = DockerError.fromException(StateError('Not connected'));
      expect(e.kind, DockerErrorKind.unknown);
      expect(e.message, 'Bad state: Not connected');
      expect(e.retryable, isFalse);
    });

    test('a DockerError passes through unchanged; wrap is idempotent', () {
      const original = DockerError(DockerErrorKind.conflict, 'busy', statusCode: 409);
      expect(identical(DockerError.fromException(original), original), isTrue);
      expect(identical(DockerError.wrap(original), original), isTrue);
      expect(DockerError.wrap(TimeoutException('t')).kind, DockerErrorKind.timeout);
    });
  });

  test('retryable table', () {
    for (final k in DockerErrorKind.values) {
      final expected = k == DockerErrorKind.network || k == DockerErrorKind.timeout || k == DockerErrorKind.server;
      expect(DockerError(k, 'm').retryable, expected, reason: '$k');
    }
  });
}
