// Draws the admin app's screens to PNG files on this PC (no phone, no emulator): the real widgets and
// fonts, answers from a stub server. Without SHOTS=1 it only checks that each screen builds.
//   SHOTS=1 flutter test test/shots/screens_test.dart
// Pictures go to ../tools/out/shots (git-ignored). The names and figures are made up for the pictures.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:admin/core/api.dart';
import 'package:admin/core/session.dart';
import 'package:admin/screens/client.dart';
import 'package:admin/screens/overview.dart';
import 'package:admin/screens/phones.dart';
import 'package:admin/screens/shell.dart';
import 'package:admin/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _shots = Platform.environment['SHOTS'] == '1';
final _boundary = GlobalKey();
const _ratio = 2.625;

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();
String _day(int back) {
  final d = DateTime.now().subtract(Duration(days: back));
  return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
}

/// What the stub server answers, by path. Replaced by each test.
final routes = <String, Object? Function(http.Request)>{};

Future<http.Response> _answer(http.Request r) async {
  final h = routes['${r.method} ${r.url.path}'] ?? routes[r.url.path];
  if (h == null) {
    return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
  }
  return http.Response.bytes(utf8.encode(jsonEncode(h(r))), 200, headers: {'content-type': 'application/json'});
}

Map<String, Object?> _overview() => {
      'branch': 'main',
      'server_time': _iso(Duration.zero),
      'services': {'ai': true, 'push': false},
      // The database sends counts as strings.
      'people': {'accounts': '31', 'students': '29', 'active_now': '3', 'today': '14', 'week': '26', 'quiet': '5', 'locked': '1'},
      'phones': {'phones': '34', 'many_phones': '2', 'many_threshold': 3},
      'versions': [
        {'version': '1.5.0', 'phones': '12'},
        {'version': '1.3.1', 'phones': '17'},
        {'version': 'older', 'phones': '5'},
      ],
      'today': {'tests_written': '23', 'writing_now': '2', 'logins': '31', 'wrong_secrets': '4', 'lockouts': '1', 'requests': '1204', 'errors': '0', 'ai_calls': '66', 'ai_failed': '1'},
      'clients': {'total': '3', 'new_week': '1', 'active_week': '3'},
      'ai_cost': {'today_inr': 2.4, 'month_inr': 38.65, 'usd_inr': 96},
      'compute': {
        'cu_hours': 18.6, 'free_cu_hours': 100, 'projected_cu_hours': 74,
        'counting_since': _iso(const Duration(days: -9)), 'resets_at': _iso(const Duration(days: 21)),
        'days': [for (var i = 0; i < 6; i++) {'day': _day(9 - i), 'cu_hours': 2.0 + i * 0.3}],
      },
      'alerts': [
        {'kind': 'phones', 'user_id': 'u-2', 'title': 'Rohan Balaji is signed in on 3 phones', 'detail': 'newest: vivo Y16', 'at': null},
        {'kind': 'locked', 'user_id': 'u-4', 'title': 'Nila Prakash is locked after 5 wrong tries', 'detail': 'unlocks by itself', 'at': _iso(const Duration(minutes: -4))},
      ],
    };

Map<String, Object?> _client({required String id, required String name, required String owner, required int students, required int tutors, int pending = 0, required int groups, required int tests, required int papers, required Duration seen, required int today, required int month, required int total, required int calls, required int failed, required double cost, required double all, int daysOld = 40}) => {
      'id': id, 'name': name, 'created_at': _iso(Duration(days: -daysOld)), 'owner': owner, 'owner_username': owner.split(' ').first.toLowerCase(),
      'students': students, 'tutors': tutors, 'pending': pending, 'groups': groups, 'tests': tests, 'papers': papers,
      'last_active_at': _iso(seen),
      'requests': {'today': today, 'week': (month * 0.3).round(), 'month': month, 'total': total},
      'ai': {'calls_month': calls, 'failed_month': failed, 'cost_month_inr': cost, 'cost_total_inr': all},
    };

Map<String, Object?> _clients() {
  final rows = [
    _client(id: 'c-1', name: 'Priya Maths Classes', owner: 'Priya Raman', students: 18, tutors: 2, pending: 2, groups: 4, tests: 9, papers: 12, seen: const Duration(minutes: -12), today: 214, month: 3980, total: 4210, calls: 142, failed: 3, cost: 18.42, all: 22.1, daysOld: 41),
    _client(id: 'c-2', name: 'Arun Science Academy', owner: 'Arun Kumar', students: 11, tutors: 1, groups: 2, tests: 5, papers: 6, seen: const Duration(hours: -5), today: 96, month: 1710, total: 1730, calls: 61, failed: 0, cost: 9.8, all: 9.8, daysOld: 20),
    _client(id: 'c-3', name: 'Meera English Hub', owner: 'Meera Nair', students: 4, tutors: 1, groups: 1, tests: 1, papers: 2, seen: const Duration(days: -2), today: 0, month: 240, total: 240, calls: 20, failed: 1, cost: 10.43, all: 10.43, daysOld: 3),
  ];
  return {
    'server_time': _iso(Duration.zero),
    'counting_since': _day(9),
    'usd_inr': 96,
    'totals': {
      'clients': 3, 'active_week': 3, 'students': 33, 'tutors': 4, 'requests_today': 310, 'requests_month': 5930,
      'ai_calls_month': 223, 'ai_cost_month_inr': 38.65, 'ai_cost_unattributed_month_inr': 0.0,
    },
    'clients': rows,
  };
}

Map<String, Object?> _clientDetail() => {
      'client': (_clients()['clients'] as List).first,
      'requests': {
        'days': [
          for (var i = 13; i >= 0; i--) {'day': _day(i), 'requests': i == 13 ? 0 : 160 + (i * 37) % 230, 'errors': 0, 'avg_ms': 180},
        ],
        'total': 4210, 'month': 3980, 'errors': 4, 'counting_since': _day(9),
      },
      'ai': {
        'cost_month_inr': 18.42, 'cost_total_inr': 22.1, 'calls_month': 142, 'failed_month': 3, 'usd_inr': 96,
        'lines': [
          {'task': 'read_paper_page', 'model': 'gemini-3.5-flash-lite', 'calls': 48, 'failed': 1, 'tokens': 96000, 'cost_inr': 6.9, 'estimated': false},
          {'task': 'answer_questions', 'model': 'openai/gpt-oss-120b', 'calls': 52, 'failed': 0, 'tokens': 208000, 'cost_inr': 4.1, 'estimated': false},
          {'task': 'answer_questions', 'model': 'gemini-3.1-flash-lite', 'calls': 30, 'failed': 2, 'tokens': 61000, 'cost_inr': 1.8, 'estimated': false},
          {'task': 'second_opinion', 'model': 'gemini-3.5-flash', 'calls': 12, 'failed': 0, 'tokens': 38000, 'cost_inr': 5.62, 'estimated': true},
        ],
        'days': [for (var i = 13; i >= 0; i--) {'day': _day(i), 'calls': i % 3 == 0 ? 0 : 9, 'cost_inr': i % 3 == 0 ? 0 : 1.1 + (i % 5) * 0.4}],
      },
      'tutors': [
        {'display_name': 'Priya Raman', 'username': 'priya.r', 'role': 'owner', 'last_seen_at': _iso(const Duration(minutes: -12))},
        {'display_name': 'Suresh Iyer', 'username': 'suresh.i', 'role': 'tutor', 'last_seen_at': _iso(const Duration(days: -1))},
      ],
      'classes': [
        {'class_level': 8, 'label': null, 'students': 6},
        {'class_level': 9, 'label': null, 'students': 9},
        {'class_level': 101, 'label': 'NEET 2027', 'students': 3},
      ],
      'last_week': {'papers': 3, 'tests': 4, 'attempts': 47},
    };

Map<String, Object?> _phones() => {
      'phones': [
        {'app': 'core_academy', 'install_id': 'i-1', 'model': 'Samsung Galaxy M14', 'os_version': 'Android 14', 'app_version': '1.5.0', 'last_seen_at': _iso(const Duration(minutes: -2)), 'accounts': [{'id': 'u-1', 'display_name': 'Harini Venkatesh'}]},
        {'app': 'core_academy', 'install_id': 'i-2', 'model': 'Redmi Note 12', 'os_version': 'Android 13', 'app_version': '1.3.1', 'last_seen_at': _iso(const Duration(hours: -3)), 'accounts': [{'id': 'u-2', 'display_name': 'Rohan Balaji'}, {'id': 'u-3', 'display_name': 'Divya Balaji'}]},
        {'app': 'admin', 'install_id': 'i-3', 'model': 'Nothing A024', 'os_version': 'Android 15', 'app_version': '1.1.0', 'last_seen_at': _iso(const Duration(minutes: -1)), 'accounts': [{'id': 'dev', 'display_name': 'Developer'}]},
      ],
      'old_app_sessions': [
        {'id': 'u-5', 'display_name': 'Sanjay Murali', 'sessions': 1, 'last_used_at': _iso(const Duration(days: -3))},
      ],
    };

Future<void> _show(WidgetTester t, Widget screen, {bool dark = false, double height = 2400}) async {
  setResolvedDark(dark);
  t.view.physicalSize = Size(1080, height);
  t.view.devicePixelRatio = _ratio;
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _boundary,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(dark ? Brightness.dark : Brightness.light), home: screen),
  ));
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 34; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  if (!_shots) return;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
    final image = await boundary.toImage(pixelRatio: _ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../tools/out/shots/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// The screen in light and dark, each saved as `name-light` and `name-dark`.
Future<void> _both(WidgetTester t, String name, Widget Function() screen, {double height = 2400, Future<void> Function(WidgetTester)? then}) async {
  for (final dark in [false, true]) {
    await _show(t, screen(), dark: dark, height: height);
    if (then != null) await then(t);
    await _shot(t, '$name-${dark ? 'dark' : 'light'}');
    await t.pumpWidget(const SizedBox.shrink()); // dispose: stops the screens' refresh timers
  }
}

/// A screenshot test. Tests draw shadows as flat blocks by default; the pictures should show them as a phone
/// does, and the test framework wants the default back before the test ends.
void shotTest(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      debugDisableShadows = false;
      try {
        await body(t);
      } finally {
        debugDisableShadows = true;
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    for (final (family, asset) in [('Geist', 'assets/fonts/Geist.ttf'), ('GeistMono', 'assets/fonts/GeistMono.ttf'), ('PhosphorLight', 'assets/fonts/PhosphorLight.ttf')]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
    // The first use of the API client makes its http client, so it is made with the stub.
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
    session.user = {'id': 'dev', 'role': 'developer', 'username': 'developer', 'display_name': 'Developer'};
  });

  setUp(() {
    routes
      ..clear()
      ..['/admin/overview'] = ((_) => _overview())
      ..['/admin/clients'] = ((_) => _clients())
      ..['/admin/clients/c-1'] = ((_) => _clientDetail())
      ..['/admin/phones'] = ((_) => _phones())
      ..['/admin/people'] = ((_) => {
            'many_threshold': 3,
            'people': [
              {'id': 'u-1', 'role': 'student', 'username': 'harini.v', 'display_name': 'Harini Venkatesh', 'class_level': 9, 'active': true, 'last_seen_at': _iso(const Duration(minutes: -1)), 'locked': false, 'phones': 2, 'app_version': '1.5.0', 'on_old_app': false},
              {'id': 'u-2', 'role': 'student', 'username': 'rohan.b', 'display_name': 'Rohan Balaji', 'class_level': 8, 'active': true, 'last_seen_at': _iso(const Duration(minutes: -12)), 'locked': false, 'phones': 3, 'app_version': '1.3.1', 'on_old_app': false},
              {'id': 'u-4', 'role': 'student', 'username': 'nila.p', 'display_name': 'Nila Prakash', 'class_level': 7, 'active': true, 'last_seen_at': _iso(const Duration(hours: -2)), 'locked': true, 'phones': 1, 'app_version': '1.3.1', 'on_old_app': false},
            ],
          });
  });

  shotTest('overview', (t) async {
    await _both(t, 'admin-overview', () => const Shell(), height: 3000);
  });

  shotTest('clients tab', (t) async {
    await _both(t, 'admin-clients', () => const Shell(), height: 2600, then: (t) async {
      Shell.go(t.element(find.byType(OverviewScreen)), Shell.clients);
      await _settle(t);
    });
  });

  shotTest('one client', (t) async {
    await _both(t, 'admin-client', () => const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
  });

  shotTest('people tab', (t) async {
    await _both(t, 'admin-people', () => const Shell(), height: 2000, then: (t) async {
      Shell.go(t.element(find.byType(OverviewScreen)), Shell.people);
      await _settle(t);
    });
  });

  shotTest('phones', (t) async {
    await _both(t, 'admin-phones', () => const PhonesScreen(), height: 2000);
  });

  shotTest('clients: nothing yet and a failure', (t) async {
    routes['/admin/clients'] = (_) => {
          'server_time': _iso(Duration.zero), 'counting_since': null, 'usd_inr': 96,
          'totals': {'clients': 0, 'active_week': 0, 'students': 0, 'tutors': 0, 'requests_today': 0, 'requests_month': 0, 'ai_calls_month': 0, 'ai_cost_month_inr': 0, 'ai_cost_unattributed_month_inr': 0},
          'clients': [],
        };
    await _both(t, 'admin-clients-empty', () => const Shell(), height: 2000, then: (t) async {
      Shell.go(t.element(find.byType(OverviewScreen)), Shell.clients);
      await _settle(t);
    });
    routes.remove('/admin/clients');
    await _both(t, 'admin-clients-error', () => const Shell(), height: 1600, then: (t) async {
      Shell.go(t.element(find.byType(OverviewScreen)), Shell.clients);
      await _settle(t);
    });
  });
}
