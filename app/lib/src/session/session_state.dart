import '../api/docker_error.dart';
import '../api/models/system_info.dart';
import '../storage/profile_store.dart';
import '../transport/transport.dart';

enum SessionStatus { disconnected, connecting, connected, reconnecting, failed }

/// Everything the UI needs to know about the current daemon connection.
class SessionState {
  final SessionStatus status;

  /// The profile being connected to or currently connected (kept after a
  /// failed connect so the Connections screen can show the error inline).
  final ConnectionProfile? profile;
  final Transport? transport;

  /// Negotiated Engine API version, e.g. "1.45".
  final String? apiVersion;
  final VersionInfo? daemon;
  final DockerError? error;

  /// 1-based reconnect attempt while reconnecting; 0 otherwise.
  final int attempt;
  final bool foreground;

  /// One-time notice for the UI (e.g. an old daemon); cleared once shown.
  final String? warning;

  /// Increments on every connect() so per-connection state can reset.
  final int sessionId;

  const SessionState({
    this.status = SessionStatus.disconnected,
    this.profile,
    this.transport,
    this.apiVersion,
    this.daemon,
    this.error,
    this.attempt = 0,
    this.foreground = true,
    this.warning,
    this.sessionId = 0,
  });

  bool get isLive => status == SessionStatus.connected && foreground;

  /// Streams may run: in the foreground and not reconnecting or failed.
  /// (Disconnected counts as usable so screens driven by an overridden
  /// transport in tests stream normally.)
  bool get streamsUsable =>
      foreground && status != SessionStatus.reconnecting && status != SessionStatus.failed;

  SessionState copyWith({
    SessionStatus? status,
    ConnectionProfile? profile,
    Transport? transport,
    String? apiVersion,
    VersionInfo? daemon,
    DockerError? error,
    bool clearError = false,
    int? attempt,
    bool? foreground,
    String? warning,
    bool clearWarning = false,
    int? sessionId,
  }) =>
      SessionState(
        status: status ?? this.status,
        profile: profile ?? this.profile,
        transport: transport ?? this.transport,
        apiVersion: apiVersion ?? this.apiVersion,
        daemon: daemon ?? this.daemon,
        error: clearError ? null : (error ?? this.error),
        attempt: attempt ?? this.attempt,
        foreground: foreground ?? this.foreground,
        warning: clearWarning ? null : (warning ?? this.warning),
        sessionId: sessionId ?? this.sessionId,
      );
}
