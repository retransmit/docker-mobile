class SystemInfo {
  final String serverVersion;
  final String os;
  final String osType;
  final String architecture;
  final String kernelVersion;
  final String storageDriver;
  final int ncpu;
  final int memTotal;
  final int containers;
  final int containersRunning;
  final int containersPaused;
  final int containersStopped;
  final int images;

  const SystemInfo({
    required this.serverVersion,
    required this.os,
    required this.osType,
    required this.architecture,
    required this.kernelVersion,
    required this.storageDriver,
    required this.ncpu,
    required this.memTotal,
    required this.containers,
    required this.containersRunning,
    required this.containersPaused,
    required this.containersStopped,
    required this.images,
  });

  factory SystemInfo.fromJson(Map<String, dynamic> json) => SystemInfo(
        serverVersion: json['ServerVersion'] as String? ?? '',
        os: json['OperatingSystem'] as String? ?? '',
        osType: json['OSType'] as String? ?? '',
        architecture: json['Architecture'] as String? ?? '',
        kernelVersion: json['KernelVersion'] as String? ?? '',
        storageDriver: json['Driver'] as String? ?? '',
        ncpu: (json['NCPU'] as num?)?.toInt() ?? 0,
        memTotal: (json['MemTotal'] as num?)?.toInt() ?? 0,
        containers: (json['Containers'] as num?)?.toInt() ?? 0,
        containersRunning: (json['ContainersRunning'] as num?)?.toInt() ?? 0,
        containersPaused: (json['ContainersPaused'] as num?)?.toInt() ?? 0,
        containersStopped: (json['ContainersStopped'] as num?)?.toInt() ?? 0,
        images: (json['Images'] as num?)?.toInt() ?? 0,
      );
}

class VersionInfo {
  final String version;
  final String apiVersion;
  final String goVersion;
  final String os;
  final String arch;

  const VersionInfo({
    required this.version,
    required this.apiVersion,
    required this.goVersion,
    required this.os,
    required this.arch,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) => VersionInfo(
        version: json['Version'] as String? ?? '',
        apiVersion: json['ApiVersion'] as String? ?? '',
        goVersion: json['GoVersion'] as String? ?? '',
        os: json['Os'] as String? ?? '',
        arch: json['Arch'] as String? ?? '',
      );
}

class DiskUsageCategory {
  final String name;
  final int count;
  final int size;
  const DiskUsageCategory({required this.name, required this.count, required this.size});
}

class DiskUsage {
  final DiskUsageCategory images;
  final DiskUsageCategory containers;
  final DiskUsageCategory volumes;
  final DiskUsageCategory buildCache;

  const DiskUsage({
    required this.images,
    required this.containers,
    required this.volumes,
    required this.buildCache,
  });

  int get total => images.size + containers.size + volumes.size + buildCache.size;

  factory DiskUsage.fromJson(Map<String, dynamic> json) {
    int sum(List? list, int Function(Map<String, dynamic>) f) =>
        (list ?? const []).fold(0, (s, e) => s + f(e as Map<String, dynamic>));
    final imgs = (json['Images'] as List?) ?? const [];
    final cons = (json['Containers'] as List?) ?? const [];
    final vols = (json['Volumes'] as List?) ?? const [];
    final cache = (json['BuildCache'] as List?) ?? const [];
    return DiskUsage(
      images: DiskUsageCategory(name: 'Images', count: imgs.length, size: sum(imgs, (m) => (m['Size'] as num?)?.toInt() ?? 0)),
      containers: DiskUsageCategory(name: 'Containers', count: cons.length, size: sum(cons, (m) => (m['SizeRw'] as num?)?.toInt() ?? 0)),
      volumes: DiskUsageCategory(name: 'Volumes', count: vols.length, size: sum(vols, (m) => ((m['UsageData'] as Map<String, dynamic>?)?['Size'] as num?)?.toInt() ?? 0)),
      buildCache: DiskUsageCategory(name: 'Build cache', count: cache.length, size: sum(cache, (m) => (m['Size'] as num?)?.toInt() ?? 0)),
    );
  }
}
