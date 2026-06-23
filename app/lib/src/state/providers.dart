import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_detail.dart';
import '../api/models/docker_container.dart';
import '../transport/transport.dart';

/// The active transport, set once the user connects. Null = not connected.
final transportProvider = StateProvider<Transport?>((ref) => null);

/// The single Docker client, derived from the active transport.
final dockerClientProvider = Provider<DockerApiClient?>((ref) {
  final transport = ref.watch(transportProvider);
  return transport == null ? null : DockerApiClient(transport);
});

/// The container list for the current connection.
final containersProvider = FutureProvider<List<DockerContainer>>((ref) async {
  final client = ref.watch(dockerClientProvider);
  if (client == null) {
    throw StateError('Not connected');
  }
  return client.listContainers();
});

/// Rich inspect for the container detail screen.
final containerDetailProvider = FutureProvider.family<ContainerDetail, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectContainerDetail(id);
});
