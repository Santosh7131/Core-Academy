// A card with a field keeps its field and its button above the keyboard, on every phone size. The cards are the real
// ones; the keyboard is given to the window the way Android gives it (insets at the bottom, and the navigation bar's
// padding gone under it), and the test asks where the card ended up. Without the keyboard the card stays in the middle.
//   flutter test test/keyboard_test.dart
import 'package:core_academy/features/teacher/course_screens.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A phone: its size in dp, and how tall its keyboard is.
typedef Phone = ({String name, double w, double h, double keyboard});

const _phones = <Phone>[
  (name: 'a 360 x 800 phone', w: 360, h: 800, keyboard: 318), // the phone in the picture that came with the report
  (name: 'a 360 x 640 phone', w: 360, h: 640, keyboard: 270),
  (name: 'a 320 x 568 phone', w: 320, h: 568, keyboard: 250),
  (name: 'a 412 x 915 phone', w: 412, h: 915, keyboard: 330),
];

const _ratio = 2.5;
const _statusBar = 24.0;
const _navBar = 16.0;

void _window(WidgetTester t, Phone p, {bool keyboardUp = false}) {
  t.view.devicePixelRatio = _ratio;
  t.view.physicalSize = Size(p.w * _ratio, p.h * _ratio);
  t.view.viewPadding = const FakeViewPadding(top: _statusBar * _ratio, bottom: _navBar * _ratio);
  // The keyboard covers the navigation bar, so no padding is left for it.
  t.view.padding = FakeViewPadding(top: _statusBar * _ratio, bottom: keyboardUp ? 0 : _navBar * _ratio);
  t.view.viewInsets = FakeViewPadding(bottom: keyboardUp ? p.keyboard * _ratio : 0);
}

Future<void> _wait(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Opens [card] from a button on an empty page, then raises the keyboard (a card's field asks for the focus at once).
Future<void> _open(WidgetTester t, Phone p, void Function(BuildContext) card, {double textScale = 1.0, bool keyboard = true}) async {
  _window(t, p);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)), child: child!),
    home: Scaffold(body: Builder(builder: (context) => Center(child: TextButton(onPressed: () => card(context), child: const Text('Open'))))),
  ));
  await t.tap(find.text('Open'));
  await _wait(t);
  if (keyboard) {
    _window(t, p, keyboardUp: true);
    await _wait(t);
  }
}

/// [what] lies inside the part of the screen the keyboard leaves: below the status bar, above the keyboard.
void _expectInView(WidgetTester t, Phone p, Finder what, String name) {
  final r = t.getRect(what);
  final keyboardTop = p.h - p.keyboard;
  expect(r.bottom, lessThanOrEqualTo(keyboardTop + 0.5), reason: '$name ends at ${r.bottom.round()} dp, under the keyboard that starts at ${keyboardTop.round()} dp');
  expect(r.top, greaterThanOrEqualTo(_statusBar - 0.5), reason: '$name starts at ${r.top.round()} dp, under the status bar');
}

void _threeFields(BuildContext context) => showCentredCard<void>(
      context,
      title: 'Add a tutor',
      subtitle: 'They log in with these, and see every group and student.',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(controller: TextEditingController(), placeholder: 'Name', autofocus: true),
          BareField(controller: TextEditingController(), placeholder: 'Username, in lowercase letters'),
          BareField(controller: TextEditingController(), placeholder: 'Password, 8 or more characters', obscure: true),
        ]),
        const SizedBox(height: 16),
        PrimaryButton('Add tutor', onTap: () => Navigator.of(ctx).pop()),
      ]),
    );

void main() {
  for (final p in _phones) {
    testWidgets('New course on ${p.name}: the field and the button sit above the keyboard', (t) async {
      await _open(t, p, (c) => newCourse(c));
      _expectInView(t, p, find.text('New course'), 'the title');
      _expectInView(t, p, find.byType(TextField), 'the field');
      _expectInView(t, p, find.widgetWithText(PrimaryButton, 'Create course'), 'the button');
    });

    testWidgets('a card with three fields on ${p.name}: the card is above the keyboard and its button can be reached', (t) async {
      await _open(t, p, _threeFields);
      _expectInView(t, p, find.text('Add a tutor'), 'the title');
      _expectInView(t, p, find.byType(SingleChildScrollView), 'the card');
      await t.ensureVisible(find.widgetWithText(PrimaryButton, 'Add tutor'));
      await _wait(t, 300);
      _expectInView(t, p, find.widgetWithText(PrimaryButton, 'Add tutor'), 'the button');
    });
  }

  testWidgets('with the text size at 1.6, on a small phone, the card is still above the keyboard and scrolls to its button', (t) async {
    const p = (name: 'a 320 x 568 phone', w: 320.0, h: 568.0, keyboard: 250.0);
    await _open(t, p, (c) => newCourse(c), textScale: 1.6);
    _expectInView(t, p, find.byType(SingleChildScrollView), 'the card');
    await t.ensureVisible(find.widgetWithText(PrimaryButton, 'Create course'));
    await _wait(t, 300);
    _expectInView(t, p, find.widgetWithText(PrimaryButton, 'Create course'), 'the button');
  });

  for (final p in _phones) {
    testWidgets('without a keyboard the card is in the middle of ${p.name}, and goes back there when the keyboard goes', (t) async {
      await _open(t, p, (c) => newCourse(c), keyboard: false);
      // The middle of the card, from its title to its button.
      double middle() => (t.getRect(find.text('New course')).top + t.getRect(find.widgetWithText(PrimaryButton, 'Create course')).bottom) / 2;
      // A little off the centre of the whole screen: the status bar and the navigation bar are not the same size.
      expect(middle(), closeTo(p.h / 2, 24));
      final before = middle();

      _window(t, p, keyboardUp: true);
      await _wait(t);
      expect(middle(), lessThan(before), reason: 'the card moves up out of the keyboard');

      _window(t, p);
      await _wait(t);
      expect(middle(), closeTo(before, 0.5), reason: 'and comes back');
    });
  }
}
