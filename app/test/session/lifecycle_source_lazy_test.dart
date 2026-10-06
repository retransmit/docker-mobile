import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/session/lifecycle_source.dart';

// Plain test()s only: a testWidgets anywhere in this file would initialise
// the binding when declared and this test could no longer fail.
void main() {
  test('creating an AppLifecycleSource does not touch the binding', () {
    expect(AppLifecycleSource.new, returnsNormally);
  });
}
