import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'containers_screen.dart';
import 'images_screen.dart';
import 'networks_screen.dart';
import 'system_screen.dart';
import 'volumes_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [ContainersScreen(), ImagesScreen(), NetworksScreen(), VolumesScreen(), SystemScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory), label: 'Containers'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Images'),
          NavigationDestination(icon: Icon(Icons.hub), label: 'Networks'),
          NavigationDestination(icon: Icon(Icons.storage), label: 'Volumes'),
          NavigationDestination(icon: Icon(Icons.monitor_heart), label: 'System'),
        ],
      ),
    );
  }
}
