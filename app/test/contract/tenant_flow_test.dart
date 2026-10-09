// The app's own session code against a running API: a tutor signs up and makes a tuition, a student
// joins a second tuition, is let in, and switches between the two. Real requests, no screens.
//   flutter test test/contract/tenant_flow_test.dart --dart-define=API_BASE=http://127.0.0.1:8787
// It leaves ctr* accounts and tuitions on the branch the API uses: node tools/out/cleanup-contract.mjs removes them.
import 'dart:io';
import 'dart:math';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // the test binding blocks real requests unless told not to

  final tag = 'ctr${Random().nextInt(9000) + 1000}';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (call) async => null);
    await session.loadPrefs();
  });

  // Only against the API on this PC: a plain `flutter test` skips it.
  final local = apiBase.startsWith('http://127.0.0.1');
  test('sign up, make a tuition, join a second one, switch', () async {
    // Tutor A signs up: a login, but no tuition yet.
    await session.signUpTutor(name: 'Contract Tutor', username: '$tag.a', password: 'longenough1');
    expect(session.isTeacher, isTrue);
    expect(session.needsTuition, isTrue);
    final a = await session.createTuition('$tag Tuition A', [
      {'class_level': 9, 'subject_name': 'Physics'},
    ]);
    expect(session.needsTuition, isFalse);
    expect(session.tuitionId, a['id']);
    expect(api.tuitionId, a['id']);
    expect(session.tuitionName, '$tag Tuition A');
    final homeA = await api.get('/teacher/home');
    expect((homeA['groups'] as List).length, 1);
    final subjectsA = (await api.get('/teacher/subjects'))['subjects'] as List;
    final physicsA = subjectsA.firstWhere((s) => s['name'] == 'Physics')['id'];
    final made = await api.post('/teacher/students', {
      'display_name': 'Contract Student', 'class_level': 9, 'username': '$tag.s', 'pin': '1357', 'subject_ids': [physicsA],
    });
    expect(made['student']['username'], '$tag.s');
    await session.logout();
    expect(session.signedIn, isFalse);
    expect(api.tuitionId, isNull);

    // Tutor B has a tuition of their own.
    await session.signUpTutor(name: 'Contract Tutor B', username: '$tag.b', password: 'longenough1');
    final b = await session.createTuition('$tag Tuition B', [
      {'class_level': 9, 'subject_name': 'Physics'},
    ]);
    final codeB = '${(await api.get('/teacher/tuition'))['tuition']['join_code_shown']}';
    expect(codeB, matches(RegExp(r'^[A-Z2-9]{3}-[A-Z2-9]{3}$')));
    await session.logout();

    // The student logs in to A, asks to join B (typed in lower case) and is waiting.
    await session.login('$tag.s', '1357');
    expect(session.isTeacher, isFalse);
    expect(session.activeTuitions.length, 1);
    expect(session.tuitionName, '$tag Tuition A');
    expect(session.classLevel, 9);
    final asked = await session.joinTuition(codeB.toLowerCase());
    expect(asked['status'], 'pending');
    expect(asked['tuition']['id'], b['id']);
    expect(session.pendingTuitions.length, 1);
    expect(session.hasChoice, isFalse);
    expect(session.needsTuition, isFalse);
    await session.logout();

    // B lets them in.
    await session.login('$tag.b', 'longenough1');
    final requests = (await api.get('/teacher/join-requests'))['requests'] as List;
    expect(requests.length, 1);
    final subjectsB = (await api.get('/teacher/subjects'))['subjects'] as List;
    final physicsB = subjectsB.firstWhere((s) => s['name'] == 'Physics')['id'];
    await api.post('/teacher/join-requests/${requests.first['id']}/accept', {'class_level': 9, 'subject_ids': [physicsB]});
    await session.logout();

    // The student now has two tuitions and switches between them.
    await session.login('$tag.s', '1357');
    expect(session.hasChoice, isTrue);
    expect(session.activeTuitions.length, 2);
    final first = session.tuitionId!;
    expect(first, a['id'], reason: 'the first tuition answers until another is chosen');
    session.switchTuition('${b['id']}');
    expect(api.tuitionId, b['id']);
    expect(session.tuitionName, '$tag Tuition B');
    final homeB = await api.get('/student/home');
    expect(homeB['tuition']['id'], b['id']);
    session.switchTuition(first);
    final homeBack = await api.get('/student/home');
    expect(homeBack['tuition']['id'], a['id']);
    await session.logout();
  }, timeout: const Timeout(Duration(seconds: 120)), skip: local ? false : 'run with --dart-define=API_BASE=http://127.0.0.1:8787');
}
