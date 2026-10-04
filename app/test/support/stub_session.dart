import 'package:docker_mobile/src/session/docker_session.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import 'fake_session.dart';

/// A session whose state the test sets directly; actions are only counted.
class StubSession extends DockerSession {
  StubSession(SessionState initial)
      : super(
          transportFactory: FakeTransportFactory(const []),
          policy: immediatePolicy(),
          lifecycle: ManualLifecycleSource(),
          invalidator: RecordingInvalidator(),
          profileStore: InMemoryProfileStore(),
        ) {
    state = initial;
  }

  int retries = 0;
  int disconnects = 0;
  int acknowledged = 0;
  final connects = <ConnectionProfile>[];

  void setState(SessionState s) => state = s;

  @override
  void retry() => retries++;

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  void acknowledgeWarning() {
    acknowledged++;
    state = state.copyWith(clearWarning: true);
  }

  @override
  Future<void> connect(ConnectionProfile profile, {String? pinOverride}) async => connects.add(profile);
}
