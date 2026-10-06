import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/transport/transport.dart';

import 'fake_transport.dart';

/// A [FakeTransport] whose POST and DELETE calls wait for [release] before
/// they answer, so a test can act while a request is in flight. GETs and
/// streams answer at once.
class HeldTransport extends FakeTransport {
  final _gate = Completer<void>();

  /// Lets the held calls, and every later one, answer.
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    await _gate.future;
    return super.post(path, query: query, body: body, headers: headers);
  }

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    await _gate.future;
    return super.delete(path, query: query);
  }
}

/// Pumps an app on [transport] whose first route reads 'first' and pushes
/// [screen] over it. Returns the navigator.
Future<NavigatorState> pumpOverFirstRoute(WidgetTester tester, Transport transport, Widget screen) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => transport)],
    child: const MaterialApp(home: Scaffold(body: Text('first'))),
  ));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
  await tester.pumpAndSettle();
  return navigator;
}

/// What the session banner's Disconnect does to the routes: back to the first one.
void popToFirstRoute(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator)).popUntil((r) => r.isFirst);
