import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/ui/connection_screen.dart';

void main() {
  runApp(const ProviderScope(child: DockerMobileApp()));
}

class DockerMobileApp extends StatelessWidget {
  const DockerMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'docker-mobile',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const ConnectionScreen(),
    );
  }
}
