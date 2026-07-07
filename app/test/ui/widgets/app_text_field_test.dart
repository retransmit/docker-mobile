import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/widgets/app_text_field.dart';

Widget _host(Widget c) => MaterialApp(home: Scaffold(body: c));

void main() {
  testWidgets('renders label + prefix icon; plain field has no eye', (tester) async {
    await tester.pumpWidget(_host(AppTextField(controller: TextEditingController(), label: 'Host', icon: Icons.dns)));
    expect(find.text('Host'), findsOneWidget);
    expect(find.byIcon(Icons.dns), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsNothing);
    expect(find.byIcon(Icons.visibility_off), findsNothing);
  });

  testWidgets('obscure field shows an eye that toggles obscureText', (tester) async {
    await tester.pumpWidget(_host(AppTextField(controller: TextEditingController(), label: 'Token', icon: Icons.key, obscure: true)));
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
  });

  testWidgets('a reused secret field re-hides after being revealed then swapped back (regression)', (tester) async {
    // Mirrors ssh_form's auth-mode switch reusing one _AppTextFieldState: reveal
    // the password, switch to the (non-obscure) key field, switch back. The
    // re-shown password field MUST default to hidden, not inherit the reveal.
    var passwordMode = true;
    late StateSetter set;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (ctx, s) {
        set = s;
        return Column(children: [
          const SizedBox(),
          if (passwordMode)
            AppTextField(controller: TextEditingController(), label: 'Password', icon: Icons.lock, obscure: true)
          else
            AppTextField(controller: TextEditingController(), label: 'Key', icon: Icons.vpn_key, maxLines: 4),
        ]);
      },
    )));
    await tester.tap(find.byIcon(Icons.visibility_off)); // reveal
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
    set(() => passwordMode = false); // -> key field (State reused)
    await tester.pump();
    set(() => passwordMode = true); // -> password field again (State reused)
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue,
        reason: 'a re-shown password field must default to hidden');
  });

  testWidgets('last field submits via onSubmit', (tester) async {
    var submitted = false;
    final c = TextEditingController();
    await tester.pumpWidget(_host(AppTextField(controller: c, label: 'Port', icon: Icons.numbers, last: true, onSubmit: () => submitted = true)));
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.done);
    await tester.showKeyboard(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isTrue);
  });
}
