import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_version.dart';
import '../api/docker_api_client.dart';
import '../api/models/docker_event.dart';
import '../api/models/system_info.dart';
import '../storage/credential_store.dart';
import '../storage/profile_store.dart';
import '../transport/transport.dart';
import 'events_hub.dart';
import 'lifecycle_source.dart';
import 'reconnect_policy.dart';
import 'session_state.dart';
import 'transport_factory.dart';

/// Builds the API client for a transport; a null [apiVersion] sends unversioned paths.
typedef ClientFactory = DockerApiClient Function(Transport transport, String? apiVersion);

DockerApiClient _defaultClient(Transport transport, String? apiVersion) =>
    DockerApiClient(transport, apiVersion: apiVersion);

/// Owns the connection to one daemon: connects and probes it, keeps an
/// events stream open as the liveness signal, reconnects with backoff when
/// that stream dies, and pauses in the background.
class DockerSession extends StateNotifier<SessionState> {
  DockerSession({
    required TransportFactory transportFactory,
    required ReconnectPolicy policy,
    required LifecycleSource lifecycle,
    required Invalidator invalidator,
    required ProfileStore profileStore,
    ClientFactory? clientFactory,
    void Function(DockerEvent)? onEvent,
    void Function()? onNewSession,
    void Function()? onProfilesChanged,
    Duration eventsDebounce = const Duration(milliseconds: 500),
    Duration dashboardDebounce = const Duration(seconds: 2),
  })  : _factory = transportFactory,
        // ignore: prefer_initializing_formals
        _policy = policy,
        // ignore: prefer_initializing_formals
        _lifecycle = lifecycle,
        // ignore: prefer_initializing_formals
        _invalidator = invalidator,
        _profiles = profileStore,
        _clientFactory = clientFactory ?? _defaultClient,
        // ignore: prefer_initializing_formals
        _onNewSession = onNewSession,
        // ignore: prefer_initializing_formals
        _onProfilesChanged = onProfilesChanged,
        super(const SessionState()) {
    _hub = EventsHub(
      open: (since) {
        final client = _client;
        if (client == null) {
          return Stream<DockerEvent>.error(const DockerError(DockerErrorKind.unknown, 'Not connected'));
        }
        return client.streamEvents(since: since);
      },
      onEvent: (e) => onEvent?.call(e),
      invalidator: invalidator,
      onLost: livenessLost,
      debounce: eventsDebounce,
      dashboardDebounce: dashboardDebounce,
    );
  }

  final TransportFactory _factory;
  final ReconnectPolicy _policy;
  final LifecycleSource _lifecycle;
  final Invalidator _invalidator;
  final ProfileStore _profiles;
  final ClientFactory _clientFactory;
  final void Function()? _onNewSession;
  final void Function()? _onProfilesChanged;
  late final EventsHub _hub;

  DockerApiClient? _client;
  Timer? _retryTimer;

  /// Attempts used by reconnects whose events stream has not yet stayed up
  /// for the policy cap; the next loss continues from here.
  int _unsettled = 0;
  Timer? _settleTimer;
  StreamSubscription<AppLifecycleState>? _lifecycleSub;
  /// Generation of the reconnect attempt in flight, if any. An attempt left
  /// over from an older generation never blocks one for the current one.
  int? _attemptGeneration;

  /// Bumped by every connect/disconnect; async work started under an older
  /// generation discards its result.
  int _generation = 0;

  bool _current(int gen) => mounted && gen == _generation;

  /// The client on the current transport, or null while not connected. It is
  /// already the new one when listeners hear about a reconnect; providers
  /// derived from [state] catch up only after their own listener has run.
  DockerApiClient? get client => _client;

  /// Builds a transport for [profile], probes the daemon and goes live.
  /// Returns true when this attempt connected the session, and false when it
  /// failed (see `state.error`), was ignored because another attempt was
  /// already in flight, or was cancelled or superseded before it finished.
  /// Throws only [HostKeyMismatchException] (and only while this attempt is
  /// still current).
  Future<bool> connect(ConnectionProfile profile, {String? pinOverride}) async {
    if (state.status == SessionStatus.connecting) return false;
    _lifecycleSub ??= _lifecycle.changes.listen(_onLifecycle);
    _stopActivity();
    final previous = state.transport;
    final gen = ++_generation;
    final sessionId = state.sessionId + 1;
    state = SessionState(
      status: SessionStatus.connecting,
      profile: profile,
      sessionId: sessionId,
      foreground: state.foreground,
    );
    unawaited(_closeQuietly(previous));
    _onNewSession?.call();

    BuiltTransport? built;
    try {
      built = await _factory.build(profile, pinOverride: pinOverride);
      if (!_current(gen)) {
        await _closeQuietly(built.transport);
        return false;
      }
      final probe = await _probe(built.transport);
      if (!_current(gen)) {
        await _closeQuietly(built.transport);
        return false;
      }
      final pinned = await _persistPin(profile, pinOverride, built.presentedHostKey);
      if (!_current(gen)) {
        await _closeQuietly(built.transport);
        return false;
      }
      _client = _clientFactory(built.transport, probe.apiVersion);
      state = state.copyWith(
        status: SessionStatus.connected,
        profile: pinned,
        transport: built.transport,
        apiVersion: probe.apiVersion,
        daemon: probe.daemon,
        warning: _warningFor(probe.daemon.apiVersion),
        attempt: 0,
      );
      _hub.start();
      if (!state.foreground) _hub.pause();
      return true;
    } on HostKeyMismatchException {
      // A superseded handshake must not raise the trust dialog.
      if (!_current(gen)) return false;
      state = SessionState(profile: profile, sessionId: sessionId, foreground: state.foreground);
      rethrow;
    } catch (e) {
      final t = built?.transport;
      if (t != null) await _closeQuietly(t);
      if (_current(gen)) {
        state = SessionState(
          profile: profile,
          sessionId: sessionId,
          foreground: state.foreground,
          error: DockerError.wrap(e),
        );
      }
      return false;
    }
  }

  /// The events stream died (error or clean end): start reconnecting. A
  /// reconnect counts as recovered only once the stream has stayed up for
  /// the policy cap; a loss before that continues the attempt count, and
  /// fails the session when the limit is used up.
  void livenessLost(DockerError error) {
    if (!mounted || state.status != SessionStatus.connected) return;
    // Drop pending refreshes too: they would hit the dead connection, and a reconnect refreshes everything.
    _hub.stop();
    _settleTimer?.cancel();
    _settleTimer = null;
    if (_unsettled >= _policy.maxAttempts) {
      state = state.copyWith(status: SessionStatus.failed, error: error);
      return;
    }
    state = state.copyWith(status: SessionStatus.reconnecting, attempt: _unsettled + 1, error: error);
    _scheduleAttempt();
  }

  /// From failed: try again now with a fresh attempt count.
  void retry() {
    if (state.status != SessionStatus.failed) return;
    _unsettled = 0;
    state = state.copyWith(status: SessionStatus.reconnecting, attempt: 1);
    unawaited(_attemptReconnect());
  }

  /// Drops the connection and returns to disconnected.
  Future<void> disconnect() async {
    _generation++;
    _stopActivity();
    final t = state.transport;
    state = SessionState(sessionId: state.sessionId, foreground: state.foreground);
    await _closeQuietly(t);
  }

  /// The UI showed [SessionState.warning]; clear it.
  void acknowledgeWarning() {
    if (state.warning != null) state = state.copyWith(clearWarning: true);
  }

  @override
  void dispose() {
    _generation++;
    _stopActivity();
    _lifecycleSub?.cancel();
    final t = state.transport;
    unawaited(_closeQuietly(t));
    super.dispose();
  }

  void _stopActivity() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _unsettled = 0;
    _hub.stop();
    _client = null;
  }

  void _scheduleAttempt() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!state.foreground || state.status != SessionStatus.reconnecting) return;
    _retryTimer = Timer(_policy.delay(state.attempt), () {
      _retryTimer = null;
      unawaited(_attemptReconnect());
    });
  }

  Future<void> _attemptReconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    final profile = state.profile;
    if (_attemptGeneration == _generation || profile == null) return;
    if (state.status != SessionStatus.reconnecting || !state.foreground) return;
    final gen = _generation;
    _attemptGeneration = gen;
    BuiltTransport? built;
    try {
      built = await _factory.build(profile);
      if (!_current(gen) || state.status != SessionStatus.reconnecting) {
        await _closeQuietly(built.transport);
        return;
      }
      final probe = await _probe(built.transport);
      if (!_current(gen) || state.status != SessionStatus.reconnecting) {
        await _closeQuietly(built.transport);
        return;
      }
      final old = state.transport;
      // Recovered only once the events stream has stayed up for the cap.
      _unsettled = state.attempt;
      _settleTimer?.cancel();
      _settleTimer = Timer(_policy.cap, () {
        _settleTimer = null;
        _unsettled = 0;
      });
      _client = _clientFactory(built.transport, probe.apiVersion);
      state = state.copyWith(
        status: SessionStatus.connected,
        transport: built.transport,
        apiVersion: probe.apiVersion,
        daemon: probe.daemon,
        attempt: 0,
        clearError: true,
      );
      // Adopted: the catch below must not close it.
      built = null;
      unawaited(_closeQuietly(old));
      // What is on screen was fetched over the old transport: refresh it in place.
      _invalidator.all();
      if (state.foreground) _hub.resume();
    } on HostKeyMismatchException {
      if (!_current(gen)) return;
      state = state.copyWith(
        status: SessionStatus.failed,
        error: const DockerError(
          DockerErrorKind.unauthorized,
          'Host key changed - reconnect from the Connections screen to review it',
        ),
      );
    } catch (e) {
      final t = built?.transport;
      if (t != null) await _closeQuietly(t);
      if (!_current(gen) || state.status != SessionStatus.reconnecting) return;
      final error = DockerError.wrap(e);
      if (!error.retryable || state.attempt >= _policy.maxAttempts) {
        state = state.copyWith(status: SessionStatus.failed, error: error);
      } else {
        state = state.copyWith(attempt: state.attempt + 1, error: error);
        _scheduleAttempt();
      }
    } finally {
      if (_attemptGeneration == gen) _attemptGeneration = null;
    }
  }

  void _onLifecycle(AppLifecycleState s) {
    if (!mounted) return;
    if (s == AppLifecycleState.paused) {
      if (!state.foreground) return;
      state = state.copyWith(foreground: false);
      _hub.pause();
      _retryTimer?.cancel();
      _retryTimer = null;
    } else if (s == AppLifecycleState.resumed) {
      if (state.foreground) return;
      state = state.copyWith(foreground: true);
      switch (state.status) {
        case SessionStatus.connected:
          unawaited(_checkAfterResume());
        case SessionStatus.reconnecting:
          unawaited(_attemptReconnect());
        case SessionStatus.disconnected:
        case SessionStatus.connecting:
        case SessionStatus.failed:
          break;
      }
    }
  }

  Future<void> _checkAfterResume() async {
    final gen = _generation;
    final client = _client;
    if (client == null) return;
    try {
      await client.ping();
      if (!_current(gen) || state.status != SessionStatus.connected || !state.foreground) return;
      _hub.resume();
    } catch (e) {
      if (!_current(gen)) return;
      livenessLost(DockerError.wrap(e));
    }
  }

  Future<({String apiVersion, VersionInfo daemon})> _probe(Transport transport) async {
    final raw = _clientFactory(transport, null);
    await raw.ping();
    final daemon = await raw.getVersion();
    return (apiVersion: negotiateApiVersion(daemon.apiVersion), daemon: daemon);
  }

  /// Saves a first-use or newly trusted SSH host key into the profile.
  Future<ConnectionProfile> _persistPin(
    ConnectionProfile profile,
    String? pinOverride,
    String? presented,
  ) async {
    final ssh = profile.ssh;
    if (profile.kind != ConnectionKind.ssh || ssh == null) return profile;
    final newPin = pinOverride ?? ssh.pinnedHostKey ?? presented;
    if (newPin == null || newPin == ssh.pinnedHostKey) return profile;
    final updated = profile.copyWith(
      ssh: SshCredentials(
        host: ssh.host,
        port: ssh.port,
        username: ssh.username,
        authMethod: ssh.authMethod,
        password: ssh.password,
        privateKeyPem: ssh.privateKeyPem,
        passphrase: ssh.passphrase,
        pinnedHostKey: newPin,
      ),
    );
    await _profiles.update(updated);
    // The pin is stored whether or not this attempt is still wanted: the list has to show it.
    if (mounted) _onProfilesChanged?.call();
    return updated;
  }

  String? _warningFor(String daemonApiVersion) {
    if (daemonApiVersion.trim().isEmpty || !isBelowMinSupported(daemonApiVersion)) return null;
    return 'This daemon speaks Docker API $daemonApiVersion. docker-mobile is tested with '
        '$kMinSupportedApiVersion and newer, so some features may not work.';
  }

  static Future<void> _closeQuietly(Transport? transport) async {
    try {
      await transport?.close();
    } catch (_) {
      // best-effort teardown
    }
  }
}
