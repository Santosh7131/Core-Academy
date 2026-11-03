// Any subject can be renamed from Settings, a standard one as well as one the tutor made. The page is the real one, against a stub
// server that answers the way the API does: the name is trimmed, a clash with another subject is refused with its own message, and the
// list shows the new name once the server has it. Maths, the first subject, can be renamed but never removed.
//   flutter test test/subject_rename_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/settings_screen.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Maths (the main one), Science (a standard subject) and Hindi (one the tutor added).
List<Map<String, dynamic>> _fresh() => [
      {'id': 'sub-maths', 'name': 'Maths', 'is_default': true, 'students': 12},
      {'id': 'sub-science', 'name': 'Science', 'is_default': false, 'students': 7},
      {'id': 'sub-hindi', 'name': 'Hindi', 'is_default': false, 'students': 0},
    ];

var _subjects = _fresh();
final _patches = <(String, Map<String, dynamic>)>[];
final _deletes = <String>[];

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Future<http.Response> _server(http.Request r) async {
  final path = r.url.path;
  if (r.method == 'GET') {
    switch (path) {
      case '/teacher/settings':
        return _json({'tuition_name': 'Priya Maths Classes', 'me': {'display_name': 'Priya'}, 'sample': {'users': 0, 'questions': 0, 'tests': 0}});
      case '/teacher/subjects':
        return _json({'subjects': _subjects});
      case '/teacher/tutors':
        return _json({
          'tutors': [
            {'id': 'u-1', 'display_name': 'Priya', 'username': 'priya', 'active': true},
          ],
          'me': 'u-1',
        });
      case '/teacher/tuition':
        return _json({'tuition': {'role': 'owner', 'join_open': true, 'join_code_shown': 'ABC123', 'pending': 0}});
    }
  }
  final subject = RegExp(r'^/teacher/subjects/([\w-]+)$').firstMatch(path);
  if (r.method == 'PATCH' && subject != null) {
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    _patches.add((subject.group(1)!, body));
    final name = (body['name'] as String).trim();
    if (name.toLowerCase() == 'taken') {
      return _json({'error': {'code': 'duplicate', 'message': 'You already have a subject called $name.'}}, 409);
    }
    _subjects = [for (final s in _subjects) s['id'] == subject.group(1) ? {...s, 'name': name} : s];
    return _json({'subject': {'id': subject.group(1), 'name': name}});
  }
  if (r.method == 'DELETE' && subject != null) {
    _deletes.add(subject.group(1)!);
    _subjects = [for (final s in _subjects) if (s['id'] != subject.group(1)) s];
    return _json({'ok': true});
  }
  return _json({'error': {'code': 'not_found', 'message': 'No stub for ${r.method} $path'}}, 404);
}

Future<void> _wait(WidgetTester t, [int ms = 600]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient(_server));
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    session.tuitionName = 'Priya Maths Classes';
  });

  setUp(() {
    _subjects = _fresh();
    _patches.clear();
    _deletes.clear();
  });

  Future<void> open(WidgetTester t) async {
    setResolvedDark(false);
    t.view.physicalSize = const Size(411 * 2.625, 4200 * 2.625);
    t.view.devicePixelRatio = 2.625;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const SettingsScreen()));
    await _wait(t);
  }

  /// Taps the subject's row, which opens its card.
  Future<void> openCard(WidgetTester t, String name) async {
    await t.ensureVisible(find.text(name).first);
    await t.tap(find.text(name).first);
    await _wait(t);
  }

  testWidgets('every subject offers Rename: Maths, a standard subject and one the tutor added', (t) async {
    await open(t);
    for (final name in ['Maths', 'Science', 'Hindi']) {
      await openCard(t, name);
      expect(find.text('Rename'), findsOneWidget, reason: '$name can be renamed');
      await t.tap(find.byIcon(Ph.x).last);
      await _wait(t);
      expect(find.text('Rename'), findsNothing, reason: 'the card closed');
    }
    expect(_patches, isEmpty, reason: 'looking changes nothing');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Remove is there for a subject that can go, and not for Maths', (t) async {
    await open(t);
    await openCard(t, 'Maths');
    expect(find.text('Remove'), findsNothing);
    await t.tap(find.byIcon(Ph.x).last);
    await _wait(t);
    await openCard(t, 'Science');
    expect(find.text('Remove'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Rename opens the name as it is, and a new one is saved trimmed and shown at once', (t) async {
    await open(t);
    await openCard(t, 'Science');
    await t.tap(find.text('Rename'));
    await _wait(t);
    expect(find.widgetWithText(TextField, 'Science'), findsOneWidget);
    await t.enterText(find.byType(TextField).last, '  General Science  ');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t, 900);
    expect([for (final (id, body) in _patches) '$id ${jsonEncode(body)}'], ['sub-science {"name":"General Science"}']);
    expect(find.text('Renamed.'), findsOneWidget);
    expect(find.text('General Science'), findsOneWidget, reason: 'the list loaded again and shows the new name');
    expect(find.text('Science'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Maths can be renamed too, and stays the one that is never removed', (t) async {
    await open(t);
    await openCard(t, 'Maths');
    await t.tap(find.text('Rename'));
    await _wait(t);
    await t.enterText(find.byType(TextField).last, 'Mathematics');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t, 900);
    expect([for (final (id, body) in _patches) '$id ${jsonEncode(body)}'], ['sub-maths {"name":"Mathematics"}']);
    await openCard(t, 'Mathematics');
    expect(find.text('Remove'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a name left empty sends nothing', (t) async {
    await open(t);
    await openCard(t, 'Hindi');
    await t.tap(find.text('Rename'));
    await _wait(t);
    await t.enterText(find.byType(TextField).last, '   ');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t, 900);
    expect(_patches, isEmpty);
    expect(find.text('Renamed.'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a name another subject has is refused in words, and the list is as it was', (t) async {
    await open(t);
    await openCard(t, 'Hindi');
    await t.tap(find.text('Rename'));
    await _wait(t);
    await t.enterText(find.byType(TextField).last, 'taken');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t, 900);
    expect(_patches.length, 1);
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('You already have a subject called taken.'), findsOneWidget);
    expect(_subjects.map((s) => s['name']), ['Maths', 'Science', 'Hindi']);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Remove still asks first, and then takes the subject away', (t) async {
    await open(t);
    await openCard(t, 'Hindi');
    await t.tap(find.text('Remove'));
    await _wait(t);
    expect(find.text('Remove Hindi?'), findsOneWidget);
    expect(_deletes, isEmpty, reason: 'nothing yet');
    await t.tap(find.text('Remove').last);
    await _wait(t, 900);
    expect(_deletes, ['sub-hindi']);
    expect(find.text('Removed.'), findsOneWidget);
    expect(find.text('Hindi'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
