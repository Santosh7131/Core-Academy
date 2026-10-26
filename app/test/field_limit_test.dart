// A field that has a limit on the server stops at that limit, so nobody types past it and meets an error afterwards.
//   flutter test test/field_limit_test.dart
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester t, List<Widget> fields) => t.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: fields))));

  testWidgets('a field with a limit stops at it, and one without takes everything', (t) async {
    final limited = TextEditingController();
    final free = TextEditingController();
    await pump(t, [
      BareField(controller: limited, placeholder: 'Limited', maxLength: 5),
      BareField(controller: free, placeholder: 'Free'),
    ]);
    await t.enterText(find.byType(TextField).at(0), '1234567890');
    await t.enterText(find.byType(TextField).at(1), '1234567890');
    expect(limited.text, '12345');
    expect(free.text, '1234567890');
  });

  testWidgets('a limit and another formatter work together', (t) async {
    final pin = TextEditingController();
    await pump(t, [
      BareField(controller: pin, placeholder: 'PIN', maxLength: 4, inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
    ]);
    await t.enterText(find.byType(TextField), 'a1b2c3d4e5');
    expect(pin.text, '1234');
  });

  testWidgets('a named field passes its limit on', (t) async {
    final c = TextEditingController();
    await pump(t, [NamedField(name: 'Tuition', controller: c, maxLength: 8)]);
    await t.enterText(find.byType(TextField), 'Priya Maths Classes');
    expect(c.text, 'Priya Ma');
  });

  testWidgets('no counter is drawn under a limited field', (t) async {
    final c = TextEditingController();
    await pump(t, [BareField(controller: c, placeholder: 'Name', maxLength: 60)]);
    await t.enterText(find.byType(TextField), 'Spoken English');
    expect(find.text('14/60'), findsNothing);
    expect(find.textContaining('/60'), findsNothing);
  });
}
