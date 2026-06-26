class ContainerStats {
  final double cpuPercent;
  final int memoryUsed;
  final int memoryLimit;
  final double memoryPercent;
  final int netRx;
  final int netTx;
  final int blockRead;
  final int blockWrite;

  const ContainerStats({
    required this.cpuPercent,
    required this.memoryUsed,
    required this.memoryLimit,
    required this.memoryPercent,
    required this.netRx,
    required this.netTx,
    required this.blockRead,
    required this.blockWrite,
  });

  factory ContainerStats.fromJson(Map<String, dynamic> json) {
    final cpu = (json['cpu_stats'] as Map?) ?? const {};
    final pre = (json['precpu_stats'] as Map?) ?? const {};
    double num_(Map m, String k) => (m[k] as num?)?.toDouble() ?? 0;
    final cpuUsage = (cpu['cpu_usage'] as Map?) ?? const {};
    final preUsage = (pre['cpu_usage'] as Map?) ?? const {};
    final cpuDelta = num_(cpuUsage, 'total_usage') - num_(preUsage, 'total_usage');
    final sysDelta = num_(cpu, 'system_cpu_usage') - num_(pre, 'system_cpu_usage');
    final online = (cpu['online_cpus'] as num?)?.toDouble() ??
        ((cpuUsage['percpu_usage'] as List?)?.length.toDouble()) ??
        1.0;
    final cpuPercent = (sysDelta > 0 && cpuDelta > 0) ? (cpuDelta / sysDelta) * online * 100 : 0.0;

    final mem = (json['memory_stats'] as Map?) ?? const {};
    final usage = (mem['usage'] as num?)?.toInt() ?? 0;
    final memStats = (mem['stats'] as Map?) ?? const {};
    final cache = (memStats['cache'] as num?)?.toInt() ?? (memStats['inactive_file'] as num?)?.toInt() ?? 0;
    final used = (usage - cache).clamp(0, usage);
    final limit = (mem['limit'] as num?)?.toInt() ?? 0;
    final memPercent = limit > 0 ? used / limit * 100 : 0.0;

    var rx = 0, tx = 0;
    final nets = (json['networks'] as Map?) ?? const {};
    for (final v in nets.values) {
      final m = (v as Map?) ?? const {};
      rx += (m['rx_bytes'] as num?)?.toInt() ?? 0;
      tx += (m['tx_bytes'] as num?)?.toInt() ?? 0;
    }

    var read = 0, write = 0;
    final blk = ((json['blkio_stats'] as Map?)?['io_service_bytes_recursive'] as List?) ?? const [];
    for (final e in blk) {
      final m = (e as Map?) ?? const {};
      final op = (m['op'] as String?)?.toLowerCase();
      final value = (m['value'] as num?)?.toInt() ?? 0;
      if (op == 'read') read += value;
      if (op == 'write') write += value;
    }

    return ContainerStats(
      cpuPercent: cpuPercent,
      memoryUsed: used,
      memoryLimit: limit,
      memoryPercent: memPercent,
      netRx: rx,
      netTx: tx,
      blockRead: read,
      blockWrite: write,
    );
  }
}
