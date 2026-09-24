import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/container_stats_screen.dart';
import 'package:docker_mobile/src/ui/widgets/skeletons.dart';

import '../support/fake_transport.dart';

const _sample =
    '{"cpu_stats":{"cpu_usage":{"total_usage":2000000000},"system_cpu_usage":10000000000,"online_cpus":4},'
    '"precpu_stats":{"cpu_usage":{"total_usage":1900000000},"system_cpu_usage":9000000000},'
    '"memory_stats":{"usage":104857600,"limit":1073741824,"stats":{"cache":4857600}},'
    '"networks":{"eth0":{"rx_bytes":1024,"tx_bytes":2048}},'
    '"blkio_stats":{"io_service_bytes_recursive":[{"op":"Read","value":4096},{"op":"Write","value":8192}]}}';

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ContainerStatsScreen(containerId: 'abc', containerName: 'web')),
    );

void main() {
  testWidgets('shows a skeleton before the first sample', (tester) async {
    await tester.pumpWidget(_wrap(FakeTransport()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(SkeletonCards), findsOneWidget);
  });

  testWidgets('renders CPU%, memory and I/O from a sample', (tester) async {
    await tester.pumpWidget(_wrap(
        FakeTransport()..onStream('/containers/abc/stats', (_) => Stream.value(utf8.encode('$_sample\n')))));
    await tester.pumpAndSettle();
    expect(find.textContaining('40.0'), findsWidgets); // CPU %
    expect(find.textContaining('CPU'), findsWidgets);
    expect(find.textContaining('Memory'), findsWidgets);
    // CPU value header (percentage) + a chart render
    expect(find.textContaining('%'), findsWidgets);
    expect(find.byType(LineChart), findsNWidgets(2)); // CPU + Memory
    // CPU big value header is its own (percentage) Text
    expect(find.text('40.0 %'), findsOneWidget);
    // memory now splits: percent value header + (used / limit) detail
    expect(find.text('9.3 %'), findsOneWidget);
    expect(find.text('95.4 MB / 1.00 GB'), findsOneWidget);
    expect(find.textContaining('/'), findsWidgets);
    // taller charts push the I/O cards below the fold; scroll them into view
    await tester.scrollUntilVisible(find.textContaining('Block'), 300);
    await tester.pumpAndSettle();
    expect(find.textContaining('Network'), findsWidgets);
    expect(find.textContaining('Block'), findsWidgets);
    // dual-metric tiles: directional labels render as their own Text widgets
    expect(find.text('RX'), findsOneWidget);
    expect(find.text('TX'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Write'), findsOneWidget);
    // byte values via MonoText (netRx 1024, netTx 2048, blockRead 4096, blockWrite 8192)
    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('4.0 KB'), findsOneWidget);
    expect(find.text('8.0 KB'), findsOneWidget);
  });
}
