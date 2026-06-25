import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/system_info.dart';

void main() {
  test('SystemInfo parses /info', () {
    final i = SystemInfo.fromJson({
      'ServerVersion': '27.0.3',
      'OperatingSystem': 'Ubuntu 24.04',
      'OSType': 'linux',
      'Architecture': 'x86_64',
      'KernelVersion': '6.8.0',
      'NCPU': 8,
      'MemTotal': 16000000000,
      'Driver': 'overlay2',
      'Containers': 5,
      'ContainersRunning': 3,
      'ContainersPaused': 0,
      'ContainersStopped': 2,
      'Images': 12,
    });
    expect(i.serverVersion, '27.0.3');
    expect(i.osType, 'linux');
    expect(i.ncpu, 8);
    expect(i.storageDriver, 'overlay2');
    expect(i.containersRunning, 3);
    expect(i.images, 12);
  });

  test('VersionInfo parses /version', () {
    final v = VersionInfo.fromJson({'Version': '27.0.3', 'ApiVersion': '1.46', 'GoVersion': 'go1.22', 'Os': 'linux', 'Arch': 'amd64'});
    expect(v.version, '27.0.3');
    expect(v.apiVersion, '1.46');
    expect(v.arch, 'amd64');
  });

  test('DiskUsage sums the df arrays into per-category totals', () {
    final df = DiskUsage.fromJson({
      'Images': [{'Size': 100}, {'Size': 50}],
      'Containers': [{'SizeRw': 10}],
      'Volumes': [{'UsageData': {'Size': 7}}, {'UsageData': {'Size': 3}}],
      'BuildCache': [{'Size': 20}],
    });
    expect(df.images.count, 2);
    expect(df.images.size, 150);
    expect(df.containers.size, 10);
    expect(df.volumes.size, 10);
    expect(df.buildCache.size, 20);
    expect(df.total, 190);
  });

  test('DiskUsage tolerates missing arrays', () {
    final df = DiskUsage.fromJson({});
    expect(df.total, 0);
    expect(df.images.count, 0);
  });
}
