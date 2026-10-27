// A course can be renamed from its own page. The page is the real one, against a stub server that answers the way the
// API does: the name is trimmed, a clash with another course is refused with its own message, and the page shows the new
// name once the server has it.
//   flutter test test/course_rename_test.dart
import 'dart:convert';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/course_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

var _name = 'Spoken English';
final _patches = <Map<String, dynamic>>[];

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Future<http.Response> _server(http.Request r) async {
  final path = r.url.path;
  if (r.method == 'GET' && path == '/teacher/courses/c1') {
    return _json({'course': {'id': 'c1', 'name': _name, 'people': 0}, 'people': <Object?>[], 'tests': <Object?>[]});
  }
  if (r.method == 'PATCH' && path == '/teacher/courses/c1') {
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    _patches.add(body);
    final name = (body['name'] as String).trim();
    if (name.toLowerCase() == 'taken') {
      return _json({'error': {'code': 'duplicate', 'message': 'You already have a course called $name.'}}, 409);
    }
    _name = name;
    return _json({'course': {'id': 'c1', 'name': _name}});
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
  });

  setUp(() {
    _name = 'Spoken English';
    _patches.clear();
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: CourseScreen(id: 'c1', name: 'Spoken English')));
    await _wait(t);
    await t.tap(find.text('Rename course'));
    await _wait(t);
  }

  testWidgets('the card starts with the name as it is, and Save waits for a different one', (t) async {
    await open(t);
    expect(find.text('Rename course'), findsNWidgets(2), reason: 'the link on the page and the card titled the same');
    expect(find.widgetWithText(TextField, 'Spoken English'), findsOneWidget);
    await t.tap(find.text('Save'));
    await _wait(t);
    expect(_patches, isEmpty, reason: 'the same name is not sent');

    await t.enterText(find.byType(TextField), 'Spoken English');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t);
    expect(_patches, isEmpty);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a new name is saved trimmed, the card closes and the page shows it', (t) async {
    await open(t);
    await t.enterText(find.byType(TextField), '  Spoken English, Batch 1  ');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t, 900);
    expect(_patches, [
      {'name': 'Spoken English, Batch 1'},
    ]);
    expect(find.text('Save'), findsNothing, reason: 'the card is gone');
    expect(find.text('Spoken English, Batch 1'), findsOneWidget, reason: 'the page loaded again and shows the new name');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a name another course has is refused in words, and the card stays open', (t) async {
    await open(t);
    await t.enterText(find.byType(TextField), 'taken');
    await _wait(t, 100);
    await t.tap(find.text('Save'));
    await _wait(t, 900);
    expect(_patches.length, 1);
    expect(find.text('You already have a course called taken.'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget, reason: 'she can type another name without opening the card again');
    expect(_name, 'Spoken English');
    await t.pumpWidget(const SizedBox());
  });
}
