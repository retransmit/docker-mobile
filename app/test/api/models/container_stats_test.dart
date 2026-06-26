import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_stats.dart';

void main() {
  test('computes CPU%, memory, network, block I/O from a stats object', () {
    final s = ContainerStats.fromJson({
      'cpu_stats': {
        'cpu_usage': {'total_usage': 2000000000},
        'system_cpu_usage': 10000000000,
        'online_cpus': 4,
      },
      'precpu_stats': {
        'cpu_usage': {'total_usage': 1900000000},
        'system_cpu_usage': 9000000000,
      },
      'memory_stats': {
        'usage': 104857600,
        'limit': 1073741824,
        'stats': {'cache': 4857600},
      },
      'networks': {
        'eth0': {'rx_bytes': 1000, 'tx_bytes': 2000},
        'eth1': {'rx_bytes': 5, 'tx_bytes': 5},
      },
      'blkio_stats': {
        'io_service_bytes_recursive': [
          {'op': 'Read', 'value': 5000},
          {'op': 'Write', 'value': 3000},
        ],
      },
    });
    expect(s.cpuPercent, closeTo(40.0, 0.001)); // (1e8/1e9)*4*100
    expect(s.memoryUsed, 100000000); // 104857600 - 4857600
    expect(s.memoryLimit, 1073741824);
    expect(s.memoryPercent, closeTo(100000000 / 1073741824 * 100, 0.001));
    expect(s.netRx, 1005);
    expect(s.netTx, 2005);
    expect(s.blockRead, 5000);
    expect(s.blockWrite, 3000);
  });

  test('system_delta <= 0 -> 0% CPU; missing sections -> 0', () {
    final s = ContainerStats.fromJson({
      'cpu_stats': {'cpu_usage': {'total_usage': 100}, 'system_cpu_usage': 100, 'online_cpus': 2},
      'precpu_stats': {'cpu_usage': {'total_usage': 50}, 'system_cpu_usage': 100},
    });
    expect(s.cpuPercent, 0.0); // system_delta == 0
    expect(s.memoryUsed, 0);
    expect(s.memoryLimit, 0);
    expect(s.memoryPercent, 0.0);
    expect(s.netRx, 0);
    expect(s.blockRead, 0);
  });
}
