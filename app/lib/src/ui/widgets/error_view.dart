import 'package:flutter/material.dart';

import '../../api/docker_error.dart';

/// The one error state used everywhere: an icon and title for the error kind,
/// the daemon's message, and a Retry button when [onRetry] is given.
/// It centers itself when there is room and scrolls when the viewport is
/// shorter than its content. [scrollable] selects a ListView with
/// AlwaysScrollableScrollPhysics so a RefreshIndicator above it works.
class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  final Widget? secondary;
  final bool scrollable;

  const ErrorView({super.key, required this.error, this.onRetry, this.secondary, this.scrollable = false});

  static IconData iconFor(DockerErrorKind kind) => switch (kind) {
        DockerErrorKind.network => Icons.wifi_off,
        DockerErrorKind.timeout => Icons.timer_off,
        DockerErrorKind.unauthorized => Icons.lock,
        DockerErrorKind.notFound => Icons.search_off,
        DockerErrorKind.conflict => Icons.sync_problem,
        DockerErrorKind.badRequest => Icons.block,
        DockerErrorKind.server => Icons.cloud_off,
        DockerErrorKind.cancelled => Icons.cancel,
        DockerErrorKind.unknown => Icons.error_outline,
      };

  static String titleFor(DockerErrorKind kind) => switch (kind) {
        DockerErrorKind.network => 'Cannot reach the daemon',
        DockerErrorKind.timeout => 'Timed out',
        DockerErrorKind.unauthorized => 'Not authorized',
        DockerErrorKind.notFound => 'Not found',
        DockerErrorKind.conflict => 'Conflict',
        DockerErrorKind.badRequest => 'Rejected by the daemon',
        DockerErrorKind.server => 'Daemon error',
        DockerErrorKind.cancelled => 'Cancelled',
        DockerErrorKind.unknown => 'Something went wrong',
      };

  @override
  Widget build(BuildContext context) {
    final err = DockerError.wrap(error);
    final theme = Theme.of(context);
    final body = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconFor(err.kind), size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(titleFor(err.kind), style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              err.message,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
            if (secondary != null) ...[
              const SizedBox(height: 8),
              secondary!,
            ],
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0),
          child: body,
        );
        if (scrollable) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [content],
          );
        }
        return SingleChildScrollView(child: content);
      },
    );
  }
}
