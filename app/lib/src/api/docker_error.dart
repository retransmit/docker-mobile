import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:web_socket_channel/web_socket_channel.dart' show WebSocketChannelException;

enum DockerErrorKind { network, timeout, unauthorized, notFound, conflict, badRequest, server, cancelled, unknown }

/// The single error type thrown by the API client and every transport.
/// [message] is always human-readable; [toString] returns it unchanged so a
/// stray `'$e'` still renders well.
class DockerError implements Exception {
  final DockerErrorKind kind;
  final String message;
  final int? statusCode;
  final Object? cause;

  const DockerError(this.kind, this.message, {this.statusCode, this.cause});

  /// Retrying the same call may succeed.
  bool get retryable =>
      kind == DockerErrorKind.network || kind == DockerErrorKind.timeout || kind == DockerErrorKind.server;

  /// A non-success HTTP response. Parses Docker's `{"message": "..."}` body,
  /// then falls back to the trimmed body text, then to a label for the kind.
  factory DockerError.fromResponse(int statusCode, String body) {
    final kind = switch (statusCode) {
      401 || 403 => DockerErrorKind.unauthorized,
      404 => DockerErrorKind.notFound,
      409 => DockerErrorKind.conflict,
      400 => DockerErrorKind.badRequest,
      >= 500 => DockerErrorKind.server,
      _ => DockerErrorKind.unknown,
    };
    return DockerError(kind, _messageFrom(body) ?? _label(kind, statusCode), statusCode: statusCode);
  }

  /// A thrown exception from a socket, TLS, timeout, or anything else.
  factory DockerError.fromException(Object e) {
    if (e is DockerError) return e;
    if (e is TimeoutException) {
      return DockerError(DockerErrorKind.timeout, 'Timed out waiting for the daemon', cause: e);
    }
    if (e is SocketException) {
      final detail = e.osError?.message ?? e.message;
      return DockerError(DockerErrorKind.network,
          _clip(detail.trim().isEmpty ? 'Cannot reach the daemon' : 'Cannot reach the daemon: ${detail.trim()}'),
          cause: e);
    }
    if (e is HandshakeException) {
      final detail = e.osError?.message;
      return DockerError(DockerErrorKind.network,
          _clip('TLS handshake failed: ${(detail == null || detail.trim().isEmpty) ? e.message : detail.trim()}'),
          cause: e);
    }
    if (e is TlsException) return DockerError(DockerErrorKind.network, _clip('TLS error: ${e.message}'), cause: e);
    if (e is WebSocketException) {
      return DockerError(DockerErrorKind.network, _clip('WebSocket error: ${e.message}'), cause: e);
    }
    if (e is HttpException) return DockerError(DockerErrorKind.network, _clip(e.message), cause: e);
    if (e is ClientException) return DockerError(DockerErrorKind.network, _clip(e.message), cause: e);
    if (e is WebSocketChannelException) {
      return DockerError(DockerErrorKind.network, _clip(e.message ?? 'WebSocket connection failed'), cause: e);
    }
    if (e is IOException) return DockerError(DockerErrorKind.network, _clip(e.toString()), cause: e);
    return DockerError(DockerErrorKind.unknown, _clip(e.toString()), cause: e);
  }

  static DockerError wrap(Object e) => e is DockerError ? e : DockerError.fromException(e);

  static String? _messageFrom(String body) {
    final t = body.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('{')) {
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          final m = decoded['message'];
          if (m is String && m.trim().isNotEmpty) return _clip(m.trim());
        }
      } catch (_) {
        // not JSON after all - fall through to the raw text
      }
    }
    if (t.startsWith('<')) return null; // HTML from a proxy - use the label instead
    return _clip(t);
  }

  static String _clip(String s) => s.length > 200 ? '${s.substring(0, 200)}...' : s;

  static String _label(DockerErrorKind kind, int status) => switch (kind) {
        DockerErrorKind.unauthorized => 'Unauthorized - check the token or certificate',
        DockerErrorKind.notFound => 'Not found',
        DockerErrorKind.conflict => 'Conflict - the resource is in use or already exists',
        DockerErrorKind.badRequest => 'The daemon rejected the request',
        DockerErrorKind.server => 'Daemon error (HTTP $status)',
        _ => 'Unexpected response (HTTP $status)',
      };

  @override
  String toString() => message;
}
