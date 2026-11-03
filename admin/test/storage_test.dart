// What each client keeps in storage, in the developer's app: a Library line on every client in the list (amber from four fifths of the
// limit), the Library of all clients together, and a Storage section on a client's own page. The screens are the real ones, against a
// stub server.
//   flutter test test/storage_test.dart
import 'dart:convert';

import 'package:admin/core/api.dart';
import 'package:admin/core/format.dart' as f;
import 'package:admin/core/session.dart';
import 'package:admin/screens/client.dart';
import 'package:admin/screens/clients.dart';
import 'package:admin/theme.dart';
import 'package:admin/ui/common.dart';
import 'package:admin/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mb = 1024 * 1024;
const _gb = 1024 * _mb;

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

/// What a tuition keeps on its Library shelves, against the 2 GB each client is allowed. Sizes in MB.
Map<String, Object?> _library({int pdfs = 0, int pdfMb = 0, int photos = 0, int photoMb = 0, int uploading = 0}) => {
      'files': pdfs + photos, 'pdfs': pdfs, 'photos': photos, 'uploading': uploading,
      'pdf_bytes': pdfMb * _mb, 'photo_bytes': photoMb * _mb, 'bytes': (pdfMb + photoMb) * _mb, 'quota_bytes': 2 * _gb,
    };

Map<String, Object?> _client(String id, String name, Map<String, Object?>? library, {Duration seen = const Duration(hours: -3)}) => {
      'id': id, 'name': name, 'created_at': _iso(const Duration(days: -40)), 'owner': 'Owner of $name', 'owner_username': 'owner',
      'students': 10, 'tutors': 1, 'pending': 0, 'groups': 2, 'tests': 3, 'papers': 4, 'last_active_at': _iso(seen),
      'library': ?library,
      'requests': {'today': 5, 'week': 40, 'month': 120, 'total': 300},
      'ai': {'calls_month': 10, 'failed_month': 0, 'cost_month_inr': 4.5, 'cost_total_inr': 9.0},
    };

/// Three clients: one with a few files, one close to its limit, one with nothing.
Map<String, Object?> _list({bool withLibrary = true}) => {
      'server_time': _iso(Duration.zero), 'counting_since': '2026-10-24', 'usd_inr': 96,
      'totals': {
        'clients': 3, 'active_week': 3, 'students': 30, 'tutors': 3, 'requests_today': 15, 'requests_month': 360,
        'ai_calls_month': 30, 'ai_cost_month_inr': 13.5, 'ai_cost_unattributed_month_inr': 0.0,
        if (withLibrary) 'library_bytes': (412 + 1740) * _mb,
      },
      'clients': [
        _client('c-1', 'Priya Maths Classes', withLibrary ? _library(pdfs: 38, pdfMb: 390, photos: 12, photoMb: 22, uploading: 1) : null, seen: const Duration(minutes: -12)),
        _client('c-2', 'Arun Science Academy', withLibrary ? _library(pdfs: 120, pdfMb: 1700, photos: 40, photoMb: 40) : null, seen: const Duration(hours: -5)),
        _client('c-3', 'Meera English Hub', withLibrary ? _library() : null, seen: const Duration(days: -2)),
      ],
    };

Map<String, Object?> _storage({Map<String, Object?>? library, int pictureMb = 6, int pageMb = 210}) {
  final lib = library ?? _library(pdfs: 38, pdfMb: 390, photos: 12, photoMb: 22, uploading: 1);
  final pictures = {'files': pictureMb == 0 ? 0 : 14, 'bytes': pictureMb * _mb};
  final pages = {'files': pageMb == 0 ? 0 : 96, 'bytes': pageMb * _mb};
  return {'library': lib, 'pictures': pictures, 'pages': pages, 'total_bytes': (lib['bytes'] as int) + pictureMb * _mb + pageMb * _mb};
}

Map<String, Object?> _detail({Map<String, Object?>? storage, bool withStorage = true}) => {
      'client': _client('c-1', 'Priya Maths Classes', null)..addAll({'join_open': true, 'plan': 'free'}),
      'storage': ?(withStorage ? (storage ?? _storage()) : null),
      'requests': {
        'days': [
          for (var i = 13; i >= 0; i--) {'day': _day(i), 'requests': 100, 'errors': 0, 'avg_ms': 180},
        ],
        'total': 300, 'month': 120, 'errors': 0, 'counting_since': '2026-10-24',
      },
      'ai': {'cost_month_inr': 4.5, 'cost_total_inr': 9.0, 'calls_month': 10, 'failed_month': 0, 'usd_inr': 96, 'lines': <Object?>[], 'days': <Object?>[]},
      'tutors': [
        {'display_name': 'Priya Raman', 'username': 'priya.r', 'role': 'owner', 'last_seen_at': _iso(const Duration(minutes: -12))},
      ],
      'classes': [
        {'class_level': 9, 'label': null, 'students': 9},
      ],
      'last_week': {'papers': 3, 'tests': 4, 'attempts': 47},
    };

String _day(int back) {
  final d = DateTime.now().subtract(Duration(days: back));
  return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
}

/// What the stub server answers, by path. Replaced by each test.
final _routes = <String, Object? Function()>{};

Future<http.Response> _answer(http.Request r) async {
  final h = _routes[r.url.path];
  if (h == null) {
    return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
  }
  return http.Response.bytes(utf8.encode(jsonEncode(h())), 200, headers: {'content-type': 'application/json'});
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _show(WidgetTester t, Widget screen, {double height = 2400}) async {
  setResolvedDark(false);
  t.view.physicalSize = Size(411 * 2.625, height * 2.625);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: screen)));
  await _settle(t);
  addTearDown(() async => t.pumpWidget(const SizedBox.shrink())); // stops the screens' refresh timers
}

/// The colour a line of text was drawn in (the text is set in spans, so it is the span's own colour).
Color? _colourOf(WidgetTester t, String text) => t.widget<Text>(find.text(text)).textSpan?.style?.color;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    // The app's own fonts: the plain test font is wider than they are, and would make rows overflow that do not on a phone.
    for (final (family, asset) in [('Geist', 'assets/fonts/Geist.ttf'), ('GeistMono', 'assets/fonts/GeistMono.ttf'), ('PhosphorLight', 'assets/fonts/PhosphorLight.ttf')]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
    session.user = {'id': 'dev', 'role': 'developer', 'username': 'developer', 'display_name': 'Developer'};
  });

  setUp(() {
    _routes
      ..clear()
      ..['/admin/clients'] = _list
      ..['/admin/clients/c-1'] = _detail;
  });

  group('sizes', () {
    test('a size is a figure and its unit', () {
      expect(f.sizeParts(0), ('0', 'B'));
      expect(f.sizeParts(500), ('500', 'B'));
      expect(f.sizeParts(2048), ('2', 'KB'));
      expect(f.sizeParts(5.5 * _mb), ('5.5', 'MB'), reason: 'a decimal under 10 MB');
      expect(f.sizeParts(12.4 * _mb), ('12', 'MB'), reason: 'none from 10 MB up');
      expect(f.sizeParts(412 * _mb), ('412', 'MB'));
      expect(f.sizeParts(1740 * _mb), ('1.7', 'GB'));
      expect(f.sizeParts(2 * _gb), ('2', 'GB'), reason: 'no ".0"');
      expect(f.sizeParts(1.96 * _gb), ('2', 'GB'), reason: 'close enough to say 2');
      expect(f.sizeParts(10.5 * _gb), ('10.5', 'GB'));
    });

    test('in a sentence it is the figure, a space and the unit', () {
      expect(f.size(412 * _mb), '412 MB');
      expect(f.size(1740 * _mb), '1.7 GB');
      expect(f.size(2 * _gb), '2 GB');
    });

    test('a Library is nearly full from four fifths of its limit', () {
      expect(nearlyFull(79, 100), isFalse);
      expect(nearlyFull(80, 100), isTrue);
      expect(nearlyFull(100, 100), isTrue);
      expect(nearlyFull(150, 100), isTrue, reason: 'over it, as a limit lowered later would leave a tuition');
      expect(nearlyFull(5, 0), isFalse, reason: 'no limit given');
      expect(nearlyFull(0, 2 * _gb), isFalse);
    });
  });

  group('the clients list', () {
    testWidgets('every client says how much Library it keeps, against the limit each is allowed', (t) async {
      await _show(t, const ClientsScreen());
      expect(find.text('Library 412 MB of 2 GB'), findsOneWidget);
      expect(find.text('Library 1.7 GB of 2 GB'), findsOneWidget);
    });

    testWidgets('a client close to its limit has that line in amber, the others in grey', (t) async {
      await _show(t, const ClientsScreen());
      expect(_colourOf(t, 'Library 1.7 GB of 2 GB'), warning);
      expect(_colourOf(t, 'Library 412 MB of 2 GB'), muted);
    });

    testWidgets('a client with nothing on its shelves says so, and does not look like a warning', (t) async {
      await _show(t, const ClientsScreen());
      expect(find.text('No Library files yet'), findsOneWidget);
      expect(_colourOf(t, 'No Library files yet'), muted);
    });

    testWidgets('a client\'s details stay together above the Library line', (t) async {
      await _show(t, const ClientsScreen());
      final name = t.getTopLeft(find.text('Priya Maths Classes')).dy;
      final row = find.ancestor(of: find.text('Priya Maths Classes'), matching: find.byType(RowTile)).first;
      final active = t.getTopLeft(find.descendant(of: row, matching: find.textContaining('Active '))).dy;
      final library = t.getTopLeft(find.text('Library 412 MB of 2 GB')).dy;
      expect(name, lessThan(active));
      expect(active, lessThan(library));
    });

    testWidgets('the figures at the end add up the Library of all clients', (t) async {
      await _show(t, const ClientsScreen());
      expect(find.text('Library files, all clients'), findsOneWidget);
      expect(find.text('2.1 GB'), findsOneWidget);
    });

    testWidgets('a server that sends no Library figures shows none of it', (t) async {
      _routes['/admin/clients'] = () => _list(withLibrary: false);
      await _show(t, const ClientsScreen());
      expect(find.text('Priya Maths Classes'), findsOneWidget);
      expect(find.textContaining('Library'), findsNothing);
    });
  });

  group('one client', () {
    testWidgets('has a Storage section: the Library against its limit, with PDFs and photos told apart', (t) async {
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      expect(find.text('STORAGE'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('2 GB for each client'), findsOneWidget);
      expect(find.text('412'), findsOneWidget);
      expect(find.text('MB'), findsOneWidget);
      expect(find.text('PDFs'), findsOneWidget);
      expect(find.text('38 · 390 MB'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      expect(find.text('12 · 22 MB'), findsOneWidget);
      expect(find.text('Still uploading'), findsOneWidget);
    });

    testWidgets('then the question pictures, the pages of papers, and everything together', (t) async {
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      expect(find.text('Question pictures'), findsOneWidget);
      expect(find.text('14 · 6.0 MB'), findsOneWidget);
      expect(find.text('Paper pages'), findsOneWidget);
      expect(find.text('96 · 210 MB'), findsOneWidget);
      expect(find.text('Everything together'), findsOneWidget);
      expect(find.text('628 MB'), findsOneWidget);
    });

    testWidgets('the section sits under the numbers of the client and above its API requests', (t) async {
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      final students = t.getTopLeft(find.text('Students')).dy;
      final storage = t.getTopLeft(find.text('STORAGE')).dy;
      final requests = t.getTopLeft(find.text('API REQUESTS')).dy;
      expect(students, lessThan(storage));
      expect(storage, lessThan(requests));
    });

    testWidgets('the bar shows how much of the limit is used, in the usual colour', (t) async {
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      final bar = t.widget<Track>(find.byType(Track));
      expect(bar.fraction, closeTo(412 / 2048, 0.0001));
      expect(bar.color, isNull);
    });

    testWidgets('close to the limit the bar turns amber', (t) async {
      _routes['/admin/clients/c-1'] = () => _detail(storage: _storage(library: _library(pdfs: 120, pdfMb: 1700, photos: 40, photoMb: 40)));
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      final bar = t.widget<Track>(find.byType(Track));
      expect(bar.color, warning);
      expect(find.text('1.7'), findsOneWidget);
      expect(find.text('GB'), findsOneWidget);
    });

    testWidgets('with no upload going on there is no "Still uploading" line', (t) async {
      _routes['/admin/clients/c-1'] = () => _detail(storage: _storage(library: _library(pdfs: 3, pdfMb: 30, photos: 2, photoMb: 4)));
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      expect(find.text('Still uploading'), findsNothing);
      expect(find.text('3 · 30 MB'), findsOneWidget);
    });

    testWidgets('a client with nothing in storage says zero, not blank', (t) async {
      _routes['/admin/clients/c-1'] = () => _detail(storage: _storage(library: _library(), pictureMb: 0, pageMb: 0));
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      Finder zeros(String inside) =>
          find.descendant(of: find.ancestor(of: find.text(inside), matching: find.byType(Surface)).first, matching: find.text('0'));
      expect(zeros('2 GB for each client'), findsNWidgets(3), reason: 'the big figure, PDFs and Photos');
      expect(zeros('Question pictures'), findsNWidgets(2), reason: 'question pictures and paper pages');
      expect(find.text('B'), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget, reason: 'everything together');
    });

    testWidgets('a server from before storage was counted gives a page without the section, not a failure', (t) async {
      _routes['/admin/clients/c-1'] = () => _detail(withStorage: false);
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      expect(find.text('STORAGE'), findsNothing);
      expect(find.text('API REQUESTS'), findsOneWidget);
    });

    testWidgets('a server that does not split PDFs from photos still shows how many there are', (t) async {
      _routes['/admin/clients/c-1'] = () {
        final lib = _library(pdfs: 38, pdfMb: 390, photos: 12, photoMb: 22)..remove('pdf_bytes')..remove('photo_bytes');
        return _detail(storage: _storage(library: lib));
      };
      await _show(t, const ClientScreen(id: 'c-1', name: 'Priya Maths Classes'), height: 4200);
      expect(find.text('38'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });
  });
}
