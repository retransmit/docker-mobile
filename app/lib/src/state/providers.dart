import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_detail.dart';
import '../api/models/container_inspect.dart';
import '../api/models/docker_container.dart';
import '../api/models/docker_image.dart';
import '../api/models/docker_network.dart';
import '../api/models/docker_volume.dart';
import '../api/models/image_detail.dart';
import '../api/models/system_info.dart';
import '../session/docker_session.dart';
import '../session/events_hub.dart';
import '../session/lifecycle_source.dart';
import '../session/reconnect_policy.dart';
import '../session/session_state.dart';
import '../session/transport_factory.dart';
import '../storage/credential_store.dart';
import '../storage/profile_store.dart';
import '../transport/ssh/ssh_connection.dart';
import '../transport/transport.dart';
import 'events_feed.dart';

/// The saved connection profiles store (overridden with an in-memory fake in tests).
final profileStoreProvider = Provider<ProfileStore>((ref) => SecureProfileStore());

/// The list of saved connection profiles.
final profilesProvider = FutureProvider<List<ConnectionProfile>>((ref) => ref.watch(profileStoreProvider).list());

/// Factory for an SSH connection to a host (overridden with a fake in tests).
final sshConnectionFactoryProvider =
    Provider<SshConnection Function(SshCredentials)>((ref) => RealSshConnection.new);

/// Builds transports from saved profiles (overridden with a fake in tests).
final transportFactoryProvider = Provider<TransportFactory>(
  (ref) => TransportFactory(sshConnectionFactory: ref.watch(sshConnectionFactoryProvider)),
);

/// Backoff for session reconnects and stream supervisors.
final reconnectPolicyProvider = Provider<ReconnectPolicy>((ref) => ReconnectPolicy());

/// App foreground/background changes (overridden with a manual source in tests).
final lifecycleSourceProvider = Provider<LifecycleSource>((ref) => AppLifecycleSource());

/// Daemon events seen since the current connection started (newest first).
final sessionEventsProvider = StateNotifierProvider<EventsFeed, EventsState>((ref) => EventsFeed());

/// The connection to the current daemon: status, transport, reconnects.
final sessionProvider = StateNotifierProvider<DockerSession, SessionState>((ref) {
  final feed = ref.read(sessionEventsProvider.notifier);
  return DockerSession(
    transportFactory: ref.read(transportFactoryProvider),
    policy: ref.read(reconnectPolicyProvider),
    lifecycle: ref.read(lifecycleSourceProvider),
    invalidator: ProviderInvalidator(ref),
    profileStore: ref.read(profileStoreProvider),
    onEvent: feed.add,
    onNewSession: feed.clear,
    onProfilesChanged: () => ref.invalidate(profilesProvider),
  );
});

/// The active transport, derived from the session. Null = not connected.
final transportProvider = Provider<Transport?>((ref) => ref.watch(sessionProvider.select((s) => s.transport)));

/// The single Docker client: the session's transport plus its negotiated
/// API version. Screens read it for one-off actions; resource providers go
/// through [resourceClient] and streams through [currentClient].
final dockerClientProvider = Provider<DockerApiClient?>((ref) {
  final transport = ref.watch(transportProvider);
  if (transport == null) return null;
  final apiVersion = ref.watch(sessionProvider.select((s) => s.apiVersion));
  return DockerApiClient(transport, apiVersion: apiVersion);
});

/// The client for work started from a session listener, such as reopening a
/// stream when the session comes back. [dockerClientProvider] can still hold
/// the previous transport at that moment, so prefer the session's own client;
/// the provider is the fallback for an overridden transport without a
/// connected session.
DockerApiClient? currentClient(Ref ref) =>
    ref.read(sessionProvider.notifier).client ?? ref.read(dockerClientProvider);

/// What the data on screen belongs to: the session id while a transport is
/// up, else null. It changes when a connection starts or ends, not when the
/// session reconnects.
final connectionScopeProvider = Provider<int?>((ref) {
  final connected = ref.watch(transportProvider.select((t) => t != null));
  final sessionId = ref.watch(sessionProvider.select((s) => s.sessionId));
  return connected ? sessionId : null;
});

/// The client for a resource provider (lists, details, the dashboard).
///
/// The provider is tied to the connection scope instead of the client. A new
/// connection is then a dependency change, so screens show their loading
/// state and nothing from the previous daemon. A reconnect leaves the
/// provider alone and the session refreshes it (see [ProviderInvalidator.all]),
/// which keeps the old data on screen until the new arrives.
DockerApiClient resourceClient(Ref ref) {
  ref.watch(connectionScopeProvider);
  final client = currentClient(ref);
  if (client == null) throw StateError('Not connected');
  return client;
}

/// Maps event categories to the providers that show them. [all] refreshes
/// everything after a reconnect, which keeps the old data on screen meanwhile.
///
/// Invalidates through [Ref.container] rather than the [Ref] itself: the ref
/// belongs to [sessionProvider], and the resource providers depend back on it
/// (via [connectionScopeProvider]), so `Ref.invalidate`'s
/// debug dependency assert would build the target and throw a
/// CircularDependencyError. The container skips that assert and ignores
/// providers that were never created (no fetch for unseen detail ids).
class ProviderInvalidator implements Invalidator {
  final Ref _ref;
  ProviderInvalidator(this._ref);

  @override
  void list(EventCategory category) {
    switch (category) {
      case EventCategory.container:
        _ref.container.invalidate(containersProvider);
      case EventCategory.image:
        _ref.container.invalidate(imagesProvider);
      case EventCategory.network:
        _ref.container.invalidate(networksProvider);
      case EventCategory.volume:
        _ref.container.invalidate(volumesProvider);
      case EventCategory.other:
        break;
    }
  }

  @override
  void detail(EventCategory category, String id) {
    switch (category) {
      case EventCategory.container:
        _ref.container.invalidate(containerDetailProvider(id));
      case EventCategory.image:
        _ref.container.invalidate(imageDetailProvider(id));
      case EventCategory.network:
      case EventCategory.volume:
      case EventCategory.other:
        break;
    }
  }

  @override
  void dashboard() => _ref.container.invalidate(systemDashboardProvider);

  @override
  void all() {
    for (final provider in resourceProviders) {
      _ref.container.invalidate(provider);
    }
  }
}

/// The container list for the current connection.
final containersProvider = FutureProvider<List<DockerContainer>>((ref) async {
  return resourceClient(ref).listContainers();
});

/// Rich inspect for the container detail screen.
final containerDetailProvider = FutureProvider.family<ContainerDetail, String>((ref, id) {
  return resourceClient(ref).inspectContainerDetail(id);
});

/// Plain inspect (the TTY flag) for the logs screen.
final containerInspectProvider = FutureProvider.family<ContainerInspect, String>((ref, id) {
  return resourceClient(ref).inspectContainer(id);
});

/// The image list for the current connection.
final imagesProvider = FutureProvider<List<DockerImage>>((ref) {
  return resourceClient(ref).listImages();
});

final imageDetailProvider = FutureProvider.family<ImageDetail, String>((ref, id) {
  return resourceClient(ref).inspectImage(id);
});

final imageHistoryProvider = FutureProvider.family<List<ImageHistoryLayer>, String>((ref, id) {
  return resourceClient(ref).imageHistory(id);
});

final networksProvider = FutureProvider<List<DockerNetwork>>((ref) {
  return resourceClient(ref).listNetworks();
});

final networkDetailProvider = FutureProvider.family<NetworkDetail, String>((ref, id) {
  return resourceClient(ref).inspectNetwork(id);
});

final volumesProvider = FutureProvider<List<DockerVolume>>((ref) {
  return resourceClient(ref).listVolumes();
});

final volumeDetailProvider = FutureProvider.family<DockerVolume, String>((ref, name) {
  return resourceClient(ref).inspectVolume(name);
});

final systemDashboardProvider =
    FutureProvider<({SystemInfo info, VersionInfo version, DiskUsage df})>((ref) async {
  final client = resourceClient(ref);
  // eagerError so the first failure (typically a timeout) surfaces immediately
  // instead of waiting on the slowest call; Future.wait still attaches handlers
  // to every future, so later errors are not unhandled.
  final results =
      await Future.wait([client.getInfo(), client.getVersion(), client.getDiskUsage()], eagerError: true);
  return (info: results[0] as SystemInfo, version: results[1] as VersionInfo, df: results[2] as DiskUsage);
});

/// Every provider that shows daemon data. A reconnect refreshes them all.
final List<ProviderOrFamily> resourceProviders = [
  containersProvider,
  containerDetailProvider,
  containerInspectProvider,
  imagesProvider,
  imageDetailProvider,
  imageHistoryProvider,
  networksProvider,
  networkDetailProvider,
  volumesProvider,
  volumeDetailProvider,
  systemDashboardProvider,
];
