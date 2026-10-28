// The sign-in screen asks the phone for a number pad while a student's PIN is typed and for the full keyboard while a tutor's password is
// typed. The phone keeps the keyboard it opened with while the same box stays active, so tapping Student or Tutor with the cursor already in
// that box left a tutor on a number pad with no letters on it. The box is entered again when the tab changes.
//   flutter test test/login_keyboard_test.dart
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/auth/login_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The keyboard the phone was last asked for.
String? _asked(WidgetTester t) => (t.testTextInput.setClientArgs?['inputType'] as Map?)?['name'] as String?;

/// Taps a tab and returns what the phone's keyboard service was told because of it.
Future<List<MethodCall>> _tap(WidgetTester t, String label) async {
  final before = t.testTextInput.log.length;
  await t.tap(find.text(label));
  await _settle(t);
  return t.testTextInput.log.skip(before).toList();
}

/// Whether the phone was told to drop its link to the box and open a new one asking for [type]. A change of type sent over the old link
/// is ignored by Android while the box stays active, which is what left a tutor on the number pad.
bool _reopenedAs(List<MethodCall> calls, String type) {
  final closed = calls.indexWhere((c) => c.method == 'TextInput.clearClient');
  final opened = calls.lastIndexWhere((c) => c.method == 'TextInput.setClient');
  if (closed < 0 || opened <= closed) return false;
  final config = (calls[opened].arguments as List)[1] as Map;
  return (config['inputType'] as Map)['name'] == type;
}

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(411 * 2.625, 900 * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const LoginScreen()));
  await t.pump(const Duration(seconds: 1)); // the boxes come in one after another
}

/// The second box: the PIN or the password.
Finder get _secret => find.byType(TextField).last;

Future<void> _settle(WidgetTester t) async {
  for (var left = 400; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
  });

  testWidgets('a student starts on the number pad for the PIN', (t) async {
    await _open(t);
    await t.tap(_secret);
    await _settle(t);
    expect(_asked(t), 'TextInputType.number');
  });

  testWidgets('tapping Tutor with the cursor already in the box asks the phone for the full keyboard', (t) async {
    await _open(t);
    await t.tap(_secret);
    await _settle(t);
    expect(_asked(t), 'TextInputType.number');
    final told = await _tap(t, 'Tutor');
    expect(_reopenedAs(told, 'TextInputType.visiblePassword'), isTrue, reason: 'the box was not left and entered again, so the phone kept the number pad and a tutor could not type a password');
    expect(_asked(t), 'TextInputType.visiblePassword');
    final box = find.descendant(of: _secret, matching: find.byType(EditableText));
    expect(t.widget<EditableText>(box).focusNode.hasFocus, isTrue, reason: 'the cursor should still be in the box');
    expect(t.testTextInput.isVisible, isTrue, reason: 'the keyboard should still be up');
  });

  testWidgets('and back to Student asks for the number pad again', (t) async {
    await _open(t);
    await t.tap(find.text('Tutor'));
    await _settle(t);
    await t.tap(_secret);
    await _settle(t);
    expect(_asked(t), 'TextInputType.visiblePassword');
    final told = await _tap(t, 'Student');
    expect(_reopenedAs(told, 'TextInputType.number'), isTrue, reason: 'the box was not left and entered again, so the full keyboard stayed up for a PIN');
    expect(_asked(t), 'TextInputType.number');
    expect(t.testTextInput.isVisible, isTrue);
  });

  testWidgets('changing the tab with no box active does not bring the keyboard up', (t) async {
    await _open(t);
    await t.tap(find.text('Tutor'));
    await _settle(t);
    expect(t.testTextInput.isVisible, isFalse);
    await t.tap(find.text('Student'));
    await _settle(t);
    expect(t.testTextInput.isVisible, isFalse);
  });

  testWidgets('moving to the username box and back still gives the tutor the full keyboard', (t) async {
    await _open(t);
    await t.tap(find.text('Tutor'));
    await _settle(t);
    await t.tap(find.byType(TextField).first);
    await _settle(t);
    await t.tap(_secret);
    await _settle(t);
    expect(_asked(t), 'TextInputType.visiblePassword');
  });
}
