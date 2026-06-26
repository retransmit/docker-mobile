import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/stats_notifier.dart';

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class ContainerStatsScreen extends ConsumerWidget {
  final String containerId;
  final String containerName;
  const ContainerStatsScreen({super.key, required this.containerId, required this.containerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(statsProvider(containerId));
    return Scaffold(
      appBar: AppBar(title: Text('Stats · $containerName')),
      body: _body(s),
    );
  }

  Widget _body(StatsState s) {
    if (s.status == StatsStatus.error) return Center(child: Text('Error: ${s.error}'));
    final latest = s.latest;
    if (latest == null) return const Center(child: Text('Waiting for stats…'));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _chartCard('CPU', '${latest.cpuPercent.toStringAsFixed(1)} %', s.cpuHistory),
        const SizedBox(height: 12),
        _chartCard(
          'Memory',
          '${_humanBytes(latest.memoryUsed)} / ${_humanBytes(latest.memoryLimit)}  (${latest.memoryPercent.toStringAsFixed(1)} %)',
          s.memHistory,
        ),
        const SizedBox(height: 12),
        _numberCard('Network', 'RX ${_humanBytes(latest.netRx)}   ·   TX ${_humanBytes(latest.netTx)}'),
        const SizedBox(height: 12),
        _numberCard('Block I/O', 'Read ${_humanBytes(latest.blockRead)}   ·   Write ${_humanBytes(latest.blockWrite)}'),
      ],
    );
  }

  Widget _chartCard(String title, String value, List<double> history) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(value),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                height: 80,
                child: LineChart(LineChartData(
                  minY: 0,
                  maxY: 100,
                  titlesData: const FlTitlesData(show: false),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [for (var i = 0; i < history.length; i++) FlSpot(i.toDouble(), history[i])],
                      isCurved: false,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                )),
              ),
            ],
          ),
        ),
      );

  Widget _numberCard(String title, String value) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(value),
          ]),
        ),
      );
}
