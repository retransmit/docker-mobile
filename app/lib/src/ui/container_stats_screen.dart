import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/stats_notifier.dart';
import 'widgets/resource_widgets.dart';

/// CPU% exceeds 100 on multi-core hosts (formula × online_cpus), so the CPU
/// chart auto-scales to the next 100 above the window's peak. Memory% is 0–100.
double _cpuMaxY(List<double> history) {
  final peak = history.isEmpty ? 0.0 : history.reduce(math.max);
  return peak <= 100 ? 100 : (peak / 100).ceil() * 100.0;
}

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
      body: _body(context, s),
    );
  }

  Widget _body(BuildContext context, StatsState s) {
    if (s.status == StatsStatus.error) return Center(child: Text('Error: ${s.error}'));
    final latest = s.latest;
    if (latest == null) return const Center(child: Text('Waiting for stats…'));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _chartCard(context, 'CPU', '${latest.cpuPercent.toStringAsFixed(1)} %', null, s.cpuHistory, _cpuMaxY(s.cpuHistory)),
        const SizedBox(height: 12),
        _chartCard(
          context,
          'Memory',
          '${latest.memoryPercent.toStringAsFixed(1)} %',
          '${_humanBytes(latest.memoryUsed)} / ${_humanBytes(latest.memoryLimit)}',
          s.memHistory,
          100,
        ),
        const SizedBox(height: 12),
        _metricCard(context, 'Network', [
          ('RX', Icons.arrow_downward, _humanBytes(latest.netRx)),
          ('TX', Icons.arrow_upward, _humanBytes(latest.netTx)),
        ]),
        const SizedBox(height: 12),
        _metricCard(context, 'Block I/O', [
          ('Read', Icons.arrow_downward, _humanBytes(latest.blockRead)),
          ('Write', Icons.arrow_upward, _humanBytes(latest.blockWrite)),
        ]),
      ],
    );
  }

  Widget _chartCard(BuildContext context, String title, String value, String? detail, List<double> history, double maxY) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: scheme.primary)),
                if (detail != null) ...[
                  const SizedBox(width: 8),
                  Expanded(child: Text(detail, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))),
                ],
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: LineChart(LineChartData(
                minY: 0,
                maxY: maxY,
                titlesData: const FlTitlesData(show: false),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (var i = 0; i < history.length; i++) FlSpot(i.toDouble(), history[i])],
                    isCurved: true,
                    preventCurveOverShooting: true,
                    barWidth: 3,
                    color: scheme.primary,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [scheme.primary.withValues(alpha: 0.30), scheme.primary.withValues(alpha: 0.0)],
                      ),
                    ),
                  ),
                ],
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricCard(BuildContext context, String title, List<(String, IconData, String)> items) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final (label, icon, value) in items)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            MonoText(value, style: text.bodyMedium),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
