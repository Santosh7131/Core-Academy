// The Library, tested the way it is used: a tutor's shelf on the page of a group and of a course (sections, files, adding, renaming, moving,
// deleting; files going up whole or in parts, stopping, trying again), and a student's Library (the bar, the classes, a class's files,
// opening and downloading). The server, the network, the file picker and the phone's storage are stand-ins from support/library_fakes.dart.
//   flutter test test/library_test.dart
import 'dart:async';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/format.dart' as fmt;
import 'package:core_academy/core/levels.dart';
import 'package:core_academy/core/library.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/library/file_viewer.dart';
import 'package:core_academy/features/library/library_widgets.dart';
import 'package:core_academy/features/student/home_screen.dart';
import 'package:core_academy/features/student/library_screens.dart';
import 'package:core_academy/features/teacher/course_screens.dart';
import 'package:core_academy/features/teacher/group_screens.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/floating_tabs.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_fakes.dart';

late LibraryServer server;
late FakeNet net;
late FakeSources sources;
late FakeStore store;

const _shelfKey = 'group:10:sub-maths';
const _pdfSize = 3984589; // "3.8 MB"
const _keepOpen = 'Keep the app open while files are added. Students see a file once it has finished, and are told about it then.';

String get _className => groupName(10, 'Maths');

// ---------------------------------------------------------------- helpers

void _screen(WidgetTester t, {double h = 2400}) {
  t.view.physicalSize = Size(411, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void _tutor() {
  api.token = 'test';
  session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'priya', 'display_name': 'Priya', 'class_level': null};
  session.tuitions = [
    {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'owner', 'status': 'active'},
  ];
  session.tuitionId = 't-1';
}

void _studentSession({int? classLevel = 10}) {
  api.token = 'test';
  session.user = {'id': 'u-2', 'role': 'student', 'username': 'asha.r', 'display_name': 'Asha Rao', 'class_level': classLevel};
  session.tuitions = [
    {'id': 't-1', 'name': 'Priya Maths Classes', 'role': 'student', 'status': 'active', 'class_level': classLevel},
  ];
  session.tuitionId = 't-1';
}

Future<void> _settle(WidgetTester t, [int ms = 2500]) async {
  for (var left = ms; left > 0; left -= 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester t, Finder target) async {
  await t.ensureVisible(target);
  await t.tap(target);
  await _settle(t, 900);
}

/// Any button the app labels for the phone's screen reader: the page's own, or one in a card in front of it.
Finder _button(String label) => find.byWidgetPredicate((w) => w is Pressable && w.label == label, description: 'a button called "$label"');

/// Presses the button called [label]; when a card in front of the page has one of the same name, that is the one pressed.
Future<void> _press(WidgetTester t, String label, {int ms = 900}) async {
  final all = _button(label);
  expect(all, findsWidgets, reason: 'there is no button called "$label"');
  final target = all.evaluate().length > 1 ? all.last : all;
  await t.ensureVisible(target);
  await t.tap(target);
  await _settle(t, ms);
}

/// How many files each section on screen holds, top to bottom.
List<int> _counts(WidgetTester t) => [for (final c in t.widgetList<CountPill>(find.byType(CountPill))) c.count];

/// The names of the files in a section of the stand-in server.
List<Object?> _names(Map<String, dynamic> section) => [for (final x in section['files'] as List) x['name']];

/// What the app sent to start each file.
List<Map<String, dynamic>> _starts() => [for (final b in server.bodies) if (b.containsKey('content_type')) b];

Future<void> _group(WidgetTester t, {bool library = true}) async {
  _tutor();
  _screen(t);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const GroupScreen(classLevel: 10, subjectId: 'sub-maths', subjectName: 'Maths')));
  await _settle(t);
  if (library) await _tap(t, find.text('Library'));
}

Future<void> _course(WidgetTester t, {bool library = true}) async {
  _tutor();
  _screen(t);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const CourseScreen(id: 'c-1', name: 'Spoken English, Batch 1')));
  await _settle(t);
  if (library) await _tap(t, find.text('Library'));
}

/// Opens the card that asks where a file comes from, in the shelf's only section, and picks [how].
Future<void> _addFileVia(WidgetTester t, String how, {int ms = 500}) async {
  await _press(t, 'Add a file');
  await _press(t, how, ms: ms);
}

/// Ends a test: whatever is still going up is let finish, and the screen is taken down so that nothing is left running.
Future<void> _end(WidgetTester t) async {
  await _settle(t, 600);
  expect(LibraryEnv.uploads.jobs.where((j) => j.state != UploadState.stopped), isEmpty, reason: 'a file was left going up');
  await t.pumpWidget(const SizedBox.shrink());
}

Map<String, Object?> _studentHome({int courses = 0, int library = 0}) => {
      'server_now': DateTime.now().toUtc().toIso8601String(),
      'tuition': {'id': 't-1', 'name': 'Priya Maths Classes'},
      'tests': <Object?>[],
      'courses': courses,
      'library': library,
    };

/// What a student of 10th Maths in a Spoken English course is shown: 4 files in 3 sections of the group, and 1 in the course.
Map<String, dynamic> _theirShelves() => {
      'groups': [
        {
          'class_level': 10,
          'subject_id': 'sub-maths',
          'subject': 'Maths',
          'sections': [
            {
              'id': 's1',
              'name': 'PDFs',
              'files': [LibraryServer.fileJson('f1', 's1', 'Chapter 1.pdf', _pdfSize), LibraryServer.fileJson('f2', 's1', 'Chapter 2.pdf', 2 * mb)],
            },
            {
              'id': 's2',
              'name': 'Books',
              'files': [LibraryServer.fileJson('f3', 's2', 'Algebra book.pdf', 40 * mb)],
            },
            {
              'id': 's3',
              'name': 'Test papers',
              'files': [LibraryServer.fileJson('f4', 's3', 'Paper 1.png', 300 * 1024)],
            },
          ],
        },
      ],
      'courses': [
        {
          'id': 'c-1',
          'name': 'Spoken English, Batch 1',
          'sections': [
            {
              'id': 's4',
              'name': 'Handouts',
              'files': [LibraryServer.fileJson('f5', 's4', 'Grammar.pdf', mb)],
            },
          ],
        },
      ],
    };

/// The student's home, inside a small router so a row can open a class page and a file can open the viewer.
Future<void> _studentApp(WidgetTester t, {int? classLevel = 10}) async {
  _studentSession(classLevel: classLevel);
  _screen(t, h: 1600);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => const StudentHome()),
    GoRoute(path: '/s/library/class', builder: (_, s) => LibraryClassScreen(shelfKey: s.uri.queryParameters['k'] ?? '', name: s.uri.queryParameters['name'] ?? '')),
    GoRoute(path: '/library/file', builder: (_, s) => FileViewerScreen(args: s.extra! as FileViewerArgs)),
  ]);
  await t.pumpWidget(MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router));
  await _settle(t);
}

List<String> _barTabs(WidgetTester t) => [for (final i in t.widget<FloatingTabs>(find.byType(FloatingTabs)).items) i.$2];

/// A student's home with files to read, opened on a class's page.
Future<void> _classPage(WidgetTester t) async {
  server.home = _studentHome(courses: 1, library: 5);
  server.courseList = [
    {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'open': 0, 'closes_at': null},
  ];
  server.student = _theirShelves();
  await _studentApp(t);
  await _press(t, 'Library');
  await _tap(t, find.text(_className));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    http.runWithClient(() => api.token = 'test', () => MockClient((r) => server.handle(r)));
    pdfPages = fakePdfPages;
  });

  setUp(() {
    server = LibraryServer();
    net = FakeNet(server);
    sources = FakeSources();
    store = FakeStore();
    LibraryEnv.sources = sources;
    LibraryEnv.store = store;
    LibraryEnv.uploads.put = net.put;
    LibraryEnv.uploads.clear();
    setResolvedDark(false);
  });

  // ================================================================ the tutor's shelf

  group('the tutor\'s Library tab', () {
    testWidgets('says how many files the shelf holds on the tab, and nothing when there are none', (t) async {
      final semantics = t.ensureSemantics();
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize), ('Diagram.png', 412 * 1024)]);
      server.seed('Books', [('Algebra.pdf', 40 * mb)]);
      await _group(t, library: false);
      expect(find.bySemanticsLabel('Library, 3'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      server.sections.clear();
      await _group(t, library: false);
      expect(find.bySemanticsLabel('Library'), findsOneWidget);
      semantics.dispose();
      await _end(t);
    });

    testWidgets('an empty shelf says so and offers the usual names for a section', (t) async {
      await _group(t);
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Or start with one of these'), findsOneWidget);
      for (final name in ['PDFs', 'Books', 'Test papers']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(_button('Add a section'), findsOneWidget);
      expect(find.text('Make tests'), findsOneWidget, reason: 'the page above the tabs is still there');
      await _end(t);
    });

    testWidgets('tapping an offered name makes that section at once', (t) async {
      await _group(t);
      await _tap(t, find.text('Books'));
      expect(server.calls, contains('POST /teacher/groups/10/sub-maths/library/sections'));
      expect(server.bodies.single, {'name': 'Books'});
      expect(find.text('Nothing here yet'), findsNothing);
      expect(find.text('Books'), findsOneWidget);
      expect(_counts(t), [0]);
      expect(_button('Add a file'), findsOneWidget, reason: 'every section ends with a row to add a file');
      await _end(t);
    });

    testWidgets('the New section card asks for a name, offers the names not used yet, and makes the section', (t) async {
      server.seed('PDFs');
      await _group(t);
      await _press(t, 'Add a section');
      expect(find.text('New section'), findsOneWidget);
      expect(find.text('Name it so students know what is inside'), findsOneWidget);
      List<String> offered() => [for (final p in t.widgetList<SuggestPill>(find.byType(SuggestPill))) p.label];
      expect(offered(), ['Books', 'Test papers'], reason: 'PDFs is already a section');
      final add = find.byWidgetPredicate((w) => w is PrimaryButton && w.label == 'Add section');
      expect(t.widget<PrimaryButton>(add).onTap, isNull, reason: 'the button waits for a name');
      await _press(t, 'Add Test papers', ms: 300);
      expect(find.widgetWithText(TextField, 'Test papers'), findsOneWidget, reason: 'a tapped name goes into the box');
      expect(offered(), ['Books'], reason: 'the name in the box is not offered again');
      expect(t.widget<PrimaryButton>(add).onTap, isNotNull);
      await _press(t, 'Add section');
      expect([for (final s in server.sections) s['name']], ['PDFs', 'Test papers']);
      expect(find.text('New section'), findsNothing);
      expect(find.text('Test papers'), findsOneWidget);
      await _end(t);
    });

    testWidgets('a name that is already used stays in the card with the reason, until the name changes', (t) async {
      server.seed('PDFs');
      await _group(t);
      await _press(t, 'Add a section');
      await t.enterText(find.byType(TextField), 'pdfs');
      await t.pump();
      await _press(t, 'Add section');
      expect(find.text('There is already a section called pdfs.'), findsOneWidget);
      expect(find.text('New section'), findsOneWidget, reason: 'the card stays open');
      expect(server.sections, hasLength(1));
      await t.enterText(find.byType(TextField), 'Notes');
      await t.pump();
      expect(find.text('There is already a section called pdfs.'), findsNothing, reason: 'typing again clears it');
      await _press(t, 'Add section');
      expect([for (final s in server.sections) s['name']], ['PDFs', 'Notes']);
      await _end(t);
    });

    testWidgets('a section shows its files with their kind, size and date, and how many it holds', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize), ('Diagram.png', 412 * 1024)]);
      server.seed('Books');
      await _group(t);
      expect(find.text('PDFs'), findsOneWidget);
      expect(find.text('Books'), findsOneWidget);
      expect(_counts(t), [2, 0]);
      expect(find.text('Chapter 1.pdf'), findsOneWidget);
      expect(find.textContaining('PDF · 3.8 MB · '), findsOneWidget);
      expect(find.text('Diagram.png'), findsOneWidget);
      expect(find.textContaining('Photo · 412 KB · '), findsOneWidget);
      expect([for (final x in t.widgetList<FileTile>(find.byType(FileTile))) x.photo], [false, true]);
      expect(_button('Add a file'), findsNWidgets(2), reason: 'one at the end of each section');
      expect(find.text(_keepOpen), findsNothing, reason: 'nothing is going up');
      await _end(t);
    });

    testWidgets('the section menu renames a section, and the new name has to be free', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize)]);
      server.seed('Books');
      await _group(t);
      await _press(t, 'Options for Books');
      expect(find.text('0 files'), findsOneWidget);
      for (final item in ['Add a file', 'Rename section', 'Delete section']) {
        expect(_button(item), findsWidgets, reason: item);
      }
      await _press(t, 'Rename section');
      expect(find.text('Rename section'), findsOneWidget);
      expect(find.text('Its files stay where they are'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Books'), findsOneWidget);
      final save = find.byWidgetPredicate((w) => w is PrimaryButton && w.label == 'Save');
      expect(t.widget<PrimaryButton>(save).onTap, isNull, reason: 'nothing changed yet');
      // The page has a search box too; the card in front of it comes last.
      await t.enterText(find.byType(TextField).last, 'pdfs');
      await t.pump();
      await _press(t, 'Save');
      expect(find.text('There is already a section called pdfs.'), findsOneWidget);
      expect(find.text('Its files stay where they are'), findsOneWidget, reason: 'the card stays open');
      await t.enterText(find.byType(TextField).last, 'Reading');
      await t.pump();
      await _press(t, 'Save');
      expect([for (final s in server.sections) s['name']], ['PDFs', 'Reading']);
      expect(server.count('PATCH /teacher/library/sections/s2'), 2);
      expect(find.text('Reading'), findsOneWidget);
      await _end(t);
    });

    testWidgets('deleting a section asks first; an empty one goes, and one with files says they go too', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize), ('Diagram.png', 412 * 1024)]);
      server.seed('Books');
      await _group(t);
      await _press(t, 'Options for Books');
      await _press(t, 'Delete section');
      expect(find.text('Delete Books?'), findsOneWidget);
      expect(find.text('This deletes the empty section Books.'), findsOneWidget);
      await _press(t, 'Cancel');
      expect(server.count('DELETE /teacher/library/sections/s2'), 0, reason: 'cancelling deletes nothing');
      expect(find.text('Books'), findsOneWidget);
      await _press(t, 'Options for Books');
      await _press(t, 'Delete section');
      await _press(t, 'Delete section');
      expect(server.calls, contains('DELETE /teacher/library/sections/s2'));
      expect([for (final s in server.sections) s['name']], ['PDFs']);
      expect(find.text('Books'), findsNothing);
      await _press(t, 'Options for PDFs');
      await _press(t, 'Delete section');
      expect(find.text('Delete PDFs?'), findsOneWidget);
      expect(find.text('This deletes PDFs and its 2 files. Students will not be able to open them any more. This cannot be undone.'), findsOneWidget);
      await _press(t, 'Delete section');
      expect(server.calls, contains('DELETE /teacher/library/sections/s1?with_files=1'));
      expect(server.sections, isEmpty);
      expect(find.text('Nothing here yet'), findsOneWidget);
      await _end(t);
    });

    testWidgets('the file menu renames a file and keeps its type', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize), ('Diagram.png', 412 * 1024)]);
      await _group(t);
      await _press(t, 'Options for Chapter 1.pdf');
      expect(find.textContaining('PDF · 3.8 MB · in PDFs'), findsOneWidget);
      for (final item in ['Rename', 'Move to another section', 'Delete this file']) {
        expect(_button(item), findsOneWidget, reason: item);
      }
      await _press(t, 'Rename');
      expect(find.text('Rename file'), findsOneWidget);
      expect(find.text('It stays a .pdf file'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Chapter 1'), findsOneWidget, reason: 'the box holds the name without its type');
      await t.enterText(find.byType(TextField).last, 'Chapter 1 notes');
      await t.pump();
      await _press(t, 'Save');
      expect(server.bodies.last, {'name': 'Chapter 1 notes.pdf'});
      expect(find.text('Chapter 1 notes.pdf'), findsOneWidget);
      expect(find.text('Chapter 1.pdf'), findsNothing);
      await _press(t, 'Options for Diagram.png');
      await _press(t, 'Rename');
      expect(find.text('It stays a .png file'), findsOneWidget);
      await _end(t);
    });

    testWidgets('a file moves to another section, and with only one section the tutor is asked to add another first', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize)]);
      await _group(t);
      await _press(t, 'Options for Chapter 1.pdf');
      await _press(t, 'Move to another section');
      expect(find.text('Add another section first'), findsOneWidget);
      expect(find.text('A file moves from one section to another. This shelf has only PDFs so far.'), findsOneWidget);
      await _press(t, 'Add a section');
      expect(find.text('New section'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, 'Books');
      await t.pump();
      await _press(t, 'Add section');
      expect([for (final s in server.sections) s['name']], ['PDFs', 'Books']);
      await _press(t, 'Options for Chapter 1.pdf');
      await _press(t, 'Move to another section');
      expect(find.text('Move to'), findsOneWidget);
      await _press(t, 'Books');
      expect(server.bodies.last, {'section_id': 's2'});
      expect(_counts(t), [0, 1]);
      expect(_names(server.sections[1]), ['Chapter 1.pdf']);
      await _end(t);
    });

    testWidgets('a file is deleted after asking, and not when the tutor cancels', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize)]);
      await _group(t);
      await _press(t, 'Options for Chapter 1.pdf');
      await _press(t, 'Delete this file');
      expect(find.text('Delete this file?'), findsOneWidget);
      expect(find.text('Chapter 1.pdf will be removed from the Library. Students will not be able to open it any more. This cannot be undone.'), findsOneWidget);
      await _press(t, 'Cancel');
      expect(server.files, 1);
      await _press(t, 'Options for Chapter 1.pdf');
      await _press(t, 'Delete this file');
      await _press(t, 'Delete file');
      expect(server.files, 0);
      expect(find.text('Chapter 1.pdf'), findsNothing);
      expect(_counts(t), [0]);
      await _end(t);
    });

    testWidgets('Remove this group stays hidden while the shelf has files', (t) async {
      server.people = 0;
      await _group(t, library: false);
      expect(find.text('Remove this group'), findsOneWidget, reason: 'an empty group can go');
      await t.pumpWidget(const SizedBox.shrink());
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize)]);
      await _group(t, library: false);
      expect(find.text('Remove this group'), findsNothing, reason: 'the server would refuse it, so it is not offered');
      await _end(t);
    });
  });

  // ================================================================ adding files

  group('adding files', () {
    testWidgets('the Add a file card offers the three ways, and closing it adds nothing', (t) async {
      server.seed('PDFs');
      await _group(t);
      await _press(t, 'Add a file');
      expect(find.text('To PDFs, in $_className'), findsOneWidget);
      for (final how in ['A PDF from this phone', 'A photo from the gallery', 'Take a photo']) {
        expect(_button(how), findsOneWidget, reason: how);
      }
      expect(find.text('PDFs and photos, up to 100 MB each.'), findsOneWidget);
      await _press(t, 'Close');
      expect(sources.asked, isEmpty);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      await _addFileVia(t, 'A PDF from this phone');
      expect(sources.asked, ['pdf']);
      expect(LibraryEnv.uploads.jobs, isEmpty, reason: 'the picker came back with nothing');
      expect(server.calls.where((c) => c.startsWith('POST')), isEmpty);
      await _end(t);
    });

    testWidgets('a file going up shows in its section with how far it has got, and counts once it has finished', (t) async {
      final semantics = t.ensureSemantics();
      server.seed('PDFs');
      await _group(t);
      final gate = Completer<void>();
      net.hold = gate.future;
      sources.pdfs = [LibraryEnv.fake('Notes.pdf', 2 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      final job = LibraryEnv.uploads.jobs.single;
      expect(job.state, UploadState.sending);
      expect(job.percent, 50);
      expect(find.text('Notes.pdf'), findsOneWidget);
      expect(find.textContaining('2.0 MB · '), findsOneWidget);
      expect(_button('Stop adding Notes.pdf'), findsOneWidget);
      expect(find.text(_keepOpen), findsOneWidget);
      expect(server.bodies.single, {'name': 'Notes.pdf', 'content_type': 'application/pdf', 'size': 2 * mb});
      expect(_counts(t), [0], reason: 'a file counts once it has finished');
      expect(find.bySemanticsLabel('Library'), findsOneWidget);
      gate.complete();
      await _settle(t, 1500);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(server.calls.where((c) => c.endsWith('/complete')), hasLength(1));
      expect(find.text('Notes.pdf'), findsOneWidget);
      expect(find.textContaining('PDF · 2.0 MB · '), findsOneWidget, reason: 'now a finished file');
      expect(find.text(_keepOpen), findsNothing);
      expect(_counts(t), [1]);
      expect(find.bySemanticsLabel('Library, 1'), findsOneWidget, reason: 'the page above loaded again');
      semantics.dispose();
      await _end(t);
    });

    testWidgets('stopping a file takes it off the shelf and off the server', (t) async {
      server.seed('PDFs');
      await _group(t);
      final gate = Completer<void>();
      net.hold = gate.future;
      sources.pdfs = [LibraryEnv.fake('Notes.pdf', 2 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      await _press(t, 'Stop adding Notes.pdf', ms: 300);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(find.text('Notes.pdf'), findsNothing);
      expect(server.calls.where((c) => c.startsWith('DELETE /teacher/library/files/')), hasLength(1));
      gate.complete();
      await _settle(t, 600);
      expect(server.calls.where((c) => c.endsWith('/complete')), isEmpty, reason: 'a stopped file is never finished');
      expect(server.files, 0);
      await _end(t);
    });

    testWidgets('files go up one at a time, in the order they were picked', (t) async {
      server.seed('PDFs');
      await _group(t);
      final gate = Completer<void>();
      net.hold = gate.future;
      sources.pdfs = [LibraryEnv.fake('A.pdf', mb), LibraryEnv.fake('B.pdf', mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      expect([for (final j in LibraryEnv.uploads.jobs) j.state], [UploadState.sending, UploadState.waiting]);
      expect(find.text('Waiting · 1.0 MB'), findsOneWidget);
      expect(LibraryEnv.uploads.busy, isTrue);
      gate.complete();
      await _settle(t, 1500);
      expect(_names(server.sections.single), ['A.pdf', 'B.pdf']);
      expect(LibraryEnv.uploads.busy, isFalse);
      expect(_counts(t), [2]);
      await _end(t);
    });

    testWidgets('no signal stops the file where it was, and Try again carries on instead of starting over', (t) async {
      server.seed('PDFs');
      await _group(t);
      net.dropNext = 1;
      sources.pdfs = [LibraryEnv.fake('Notes.pdf', 2 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      expect(LibraryEnv.uploads.jobs.single.state, UploadState.stopped);
      expect(find.text('Stopped at 50%, no signal'), findsOneWidget);
      expect(_button('Try again'), findsOneWidget);
      expect(_button('Stop adding Notes.pdf'), findsNothing);
      await _press(t, 'Try again', ms: 1500);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(server.files, 1);
      expect(server.calls.where((c) => c == 'POST /teacher/library/sections/s1/files'), hasLength(1), reason: 'the file was started once');
      expect(server.calls.where((c) => c.endsWith('/upload')), hasLength(1), reason: 'and asked for again to carry on');
      await _end(t);
    });

    testWidgets('storage refusing the file starts it again from the beginning on Try again', (t) async {
      server.seed('PDFs');
      await _group(t);
      net.status = 500;
      sources.pdfs = [LibraryEnv.fake('Notes.pdf', 2 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      expect(find.text('The file did not go up. Try again.'), findsOneWidget);
      expect(_button('Try again'), findsOneWidget);
      net.status = 200;
      await _press(t, 'Try again', ms: 1500);
      expect(server.files, 1);
      expect(server.calls.where((c) => c == 'POST /teacher/library/sections/s1/files'), hasLength(2), reason: 'the first try was thrown away');
      await _end(t);
    });

    testWidgets('a full Library stops the file for good, with no Try again, and the tutor can remove it', (t) async {
      server.seed('PDFs');
      await _group(t);
      server.refuseStart = (status: 413, code: 'library_full', message: 'The Library is full. Delete some files to make room.');
      sources.pdfs = [LibraryEnv.fake('Notes.pdf', 2 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      expect(find.text('The Library is full. Delete some files to make room.'), findsOneWidget);
      expect(_button('Try again'), findsNothing);
      await _press(t, 'Remove Notes.pdf', ms: 300);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(find.text('Notes.pdf'), findsNothing);
      expect(server.calls.where((c) => c.startsWith('DELETE')), isEmpty, reason: 'nothing had reached the server');
      await _end(t);
    });

    testWidgets('photos from the gallery and the camera go up as photos, and a camera that came back empty adds nothing', (t) async {
      server.seed('PDFs');
      await _group(t);
      sources.photos = [LibraryEnv.fake('IMG_1.jpg', 500 * 1024), LibraryEnv.fake('IMG_2.png', 300 * 1024)];
      await _addFileVia(t, 'A photo from the gallery', ms: 1500);
      expect(server.files, 2);
      expect([for (final x in t.widgetList<FileTile>(find.byType(FileTile))) x.photo], [true, true]);
      expect(_starts(), [
        {'name': 'IMG_1.jpg', 'content_type': 'image/jpeg', 'size': 500 * 1024},
        {'name': 'IMG_2.png', 'content_type': 'image/png', 'size': 300 * 1024},
      ]);
      sources.camera = LibraryEnv.fake('Photo 2 Nov 2026 5.42 pm.jpg', 400 * 1024);
      await _addFileVia(t, 'Take a photo', ms: 1500);
      expect(server.files, 3);
      sources.camera = null;
      await _addFileVia(t, 'Take a photo');
      expect(server.files, 3);
      expect(sources.asked, ['gallery', 'camera', 'camera']);
      await _end(t);
    });

    testWidgets('files over 100 MB are refused with the reason, and the others go up', (t) async {
      server.seed('PDFs');
      await _group(t);
      sources.pdfs = [LibraryEnv.fake('Huge.pdf', 101 * mb)];
      await _addFileVia(t, 'A PDF from this phone');
      expect(find.text('That did not work'), findsOneWidget);
      expect(find.text('Huge.pdf is bigger than 100 MB, so it cannot be added.'), findsOneWidget);
      await _press(t, 'OK');
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(server.calls.where((c) => c.startsWith('POST')), isEmpty);
      sources.pdfs = [LibraryEnv.fake('Huge.pdf', 101 * mb), LibraryEnv.fake('Big.pdf', 150 * mb), LibraryEnv.fake('Small.pdf', mb), LibraryEnv.fake('Empty.pdf', 0)];
      await _addFileVia(t, 'A PDF from this phone');
      expect(find.text('2 of those files are bigger than 100 MB, so they cannot be added.'), findsOneWidget);
      await _press(t, 'OK', ms: 1500);
      expect(_names(server.sections.single), ['Small.pdf'], reason: 'the empty file is left out without a word');
      await _end(t);
    });

    testWidgets('a phone that will not give the file says so', (t) async {
      server.seed('PDFs');
      await _group(t);
      sources.fail = PlatformException(code: 'denied', message: 'No permission.');
      await _addFileVia(t, 'A photo from the gallery');
      expect(find.text('That did not work'), findsOneWidget);
      expect(find.text('The phone would not give the file. No permission.'), findsOneWidget);
      await _press(t, 'OK');
      expect(LibraryEnv.uploads.jobs, isEmpty);
      await _end(t);
    });

    testWidgets('a big file goes up in parts of 8 MB, each to its own link', (t) async {
      server.seed('PDFs');
      await _group(t);
      sources.pdfs = [LibraryEnv.fake('Book.pdf', 20 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 2000);
      expect([for (final p in net.puts) p.length], [8 * mb, 8 * mb, 4 * mb]);
      expect([for (final p in net.puts) p.url.split('/').last], ['1', '2', '3']);
      expect(server.files, 1);
      expect(find.text('Book.pdf'), findsOneWidget);
      await _end(t);
    });

    testWidgets('a part that did not arrive is asked for and sent again before the file is finished', (t) async {
      server.seed('PDFs');
      await _group(t);
      server.incompleteCompletes = 1;
      sources.pdfs = [LibraryEnv.fake('Book.pdf', 20 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 2000);
      expect([for (final p in net.puts) p.length], [8 * mb, 8 * mb, 4 * mb, 8 * mb]);
      expect(net.puts.last.url.endsWith('/2'), isTrue, reason: 'only the missing part went again');
      expect(server.calls.where((c) => c.endsWith('/complete')), hasLength(2));
      expect(server.files, 1);
      await _end(t);
    });

    testWidgets('a part that loses its connection is sent again after a short wait', (t) async {
      server.seed('PDFs');
      await _group(t);
      net.dropNext = 1;
      sources.pdfs = [LibraryEnv.fake('Book.pdf', 20 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      expect(net.puts, isEmpty);
      expect(LibraryEnv.uploads.jobs.single.state, UploadState.sending, reason: 'it is waiting to try again, not stopped');
      expect(LibraryEnv.uploads.jobs.single.sent, 0);
      await _settle(t, 4000);
      expect([for (final p in net.puts) p.length], [8 * mb, 8 * mb, 4 * mb]);
      expect(server.files, 1);
      await _end(t);
    });

    testWidgets('three lost connections in a row stop the file, and Try again sends the parts again', (t) async {
      server.seed('PDFs');
      await _group(t);
      net.dropNext = 3;
      sources.pdfs = [LibraryEnv.fake('Book.pdf', 20 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      await _settle(t, 7500);
      expect(find.text('Stopped at 0%, no signal'), findsOneWidget);
      expect(_button('Try again'), findsOneWidget);
      await _press(t, 'Try again', ms: 2500);
      expect([for (final p in net.puts) p.length], [8 * mb, 8 * mb, 4 * mb]);
      expect(server.files, 1);
      expect(server.calls.where((c) => c == 'POST /teacher/library/sections/s1/files'), hasLength(1));
      expect(server.calls.where((c) => c.endsWith('/upload')), hasLength(1));
      await _end(t);
    });

    testWidgets('files are queued per shelf, and the queue can be emptied', (t) async {
      _tutor();
      server.seed('PDFs');
      final gate = Completer<void>();
      net.hold = gate.future;
      LibraryEnv.uploads.add(_shelfKey, 's1', [LibraryEnv.fake('A.pdf', mb), LibraryEnv.fake('B.pdf', mb)]);
      LibraryEnv.uploads.add('course:c-1', 's1', [LibraryEnv.fake('C.pdf', mb)]);
      await _settle(t, 300);
      expect(LibraryEnv.uploads.forShelf(_shelfKey), hasLength(2));
      expect(LibraryEnv.uploads.forShelf('course:c-1'), hasLength(1));
      expect(LibraryEnv.uploads.forShelf('group:9:sub-maths'), isEmpty);
      expect(LibraryEnv.uploads.busy, isTrue);
      gate.complete();
      await _settle(t, 1500);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(LibraryEnv.uploads.busy, isFalse);
      expect(server.files, 3);
      await t.pumpWidget(const SizedBox.shrink());
    });
  });

  // ================================================================ a course's shelf

  group('a course\'s shelf', () {
    testWidgets('a course page has the same Library tab, on the course\'s own shelf', (t) async {
      await _course(t);
      expect(find.text('Nothing here yet'), findsOneWidget);
      await _tap(t, find.text('Books'));
      expect(server.calls, contains('POST /teacher/courses/c-1/library/sections'));
      expect(find.text('Books'), findsOneWidget);
      sources.pdfs = [LibraryEnv.fake('Grammar.pdf', mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 1500);
      expect(find.text('Grammar.pdf'), findsOneWidget);
      expect(LibraryEnv.uploads.jobs, isEmpty);
      expect(_counts(t), [1]);
      expect(find.text('Rename course'), findsOneWidget, reason: 'the page above the tabs is still there');
      await _end(t);
    });

    testWidgets('deleting a course says its Library files go too, but only when it has some', (t) async {
      server.seed('PDFs', [('Chapter 1.pdf', _pdfSize)]);
      await _course(t, library: false);
      await _tap(t, find.text('Delete this course'));
      expect(find.textContaining('its Library files'), findsOneWidget);
      await _press(t, 'Cancel');
      await t.pumpWidget(const SizedBox.shrink());
      server.sections.clear();
      await _course(t, library: false);
      await _tap(t, find.text('Delete this course'));
      expect(find.text('Delete this course?'), findsOneWidget);
      expect(find.textContaining('its Library files'), findsNothing);
      await _press(t, 'Cancel');
      await _end(t);
    });
  });

  // ================================================================ the student's Library

  group('the student\'s Library', () {
    testWidgets('with no files to read there is no Library tab and no bar', (t) async {
      server.home = _studentHome();
      await _studentApp(t);
      expect(find.byType(FloatingTabs), findsNothing);
      expect(find.text('Library'), findsNothing);
      await _end(t);
    });

    testWidgets('a student in a class gets Home and Library, and with a course too, Courses in between', (t) async {
      server.home = _studentHome(library: 5);
      server.student = _theirShelves();
      await _studentApp(t);
      expect(_barTabs(t), ['Home', 'Library']);
      await t.pumpWidget(const SizedBox.shrink());
      server.home = _studentHome(courses: 1, library: 5);
      server.courseList = [
        {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'open': 0, 'closes_at': null},
      ];
      await _studentApp(t);
      expect(_barTabs(t), ['Home', 'Courses', 'Library']);
      await _end(t);
    });

    testWidgets('a person who is only in courses has Home and Library', (t) async {
      server.home = _studentHome(courses: 1, library: 1);
      server.courseList = [
        {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'open': 0, 'closes_at': null},
      ];
      server.student = {'groups': <Object?>[], 'courses': (_theirShelves()['courses'] as List)};
      await _studentApp(t, classLevel: null);
      expect(_barTabs(t), ['Home', 'Library'], reason: 'their courses are on Home, so there is no Courses tab');
      await _press(t, 'Library');
      expect(find.text('Spoken English, Batch 1'), findsOneWidget);
      expect([for (final c in t.widgetList<TagChip>(find.byType(TagChip))) c.text], ['Course']);
      await _end(t);
    });

    testWidgets('the Library tab lists the classes that have files, groups first, each with how much it holds', (t) async {
      server.home = _studentHome(courses: 1, library: 5);
      server.courseList = [
        {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'open': 0, 'closes_at': null},
      ];
      server.student = _theirShelves();
      await _studentApp(t);
      await _press(t, 'Library');
      expect(find.text(_className), findsOneWidget);
      expect(find.text('4 files in 3 sections'), findsOneWidget);
      expect(find.text('Spoken English, Batch 1'), findsOneWidget);
      expect(find.text('1 file in 1 section'), findsOneWidget);
      expect([for (final c in t.widgetList<TagChip>(find.byType(TagChip))) c.text], ['Group', 'Course']);
      expect(t.getTopLeft(find.text(_className)).dy, lessThan(t.getTopLeft(find.text('Spoken English, Batch 1')).dy));
      await _end(t);
    });

    testWidgets('a class page lists its sections and files, can change nothing, and Download saves a copy', (t) async {
      await _classPage(t);
      for (final name in ['PDFs', 'Books', 'Test papers']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('Chapter 1.pdf'), findsOneWidget);
      expect(find.text('Paper 1.png'), findsOneWidget);
      expect(_counts(t), [2, 1, 1]);
      expect(_button('Add a file'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is Pressable && (w.label ?? '').startsWith('Options for')), findsNothing);
      await _press(t, 'Download Chapter 1.pdf');
      expect(store.fetched, ['student:f1']);
      expect(store.saved, ['Chapter 1.pdf']);
      expect(find.text('Chapter 1.pdf is saved in Downloads.'), findsOneWidget);
      store.savedTo = null;
      await _press(t, 'Download Chapter 2.pdf');
      expect(store.saved, ['Chapter 1.pdf', 'Chapter 2.pdf']);
      expect(find.textContaining('is saved in'), findsNothing, reason: 'the share sheet opened instead, so there is nothing to say');
      store.failWith = 'No internet connection. Check your connection and try again.';
      await _press(t, 'Download Chapter 1.pdf');
      expect(find.text('No internet connection. Check your connection and try again.'), findsOneWidget);
      expect(store.saved, hasLength(2), reason: 'nothing was saved');
      await _end(t);
    });

    testWidgets('opening a PDF shows where it is, its name and its page, and Download saves it', (t) async {
      await _classPage(t);
      await _tap(t, find.text('Chapter 1.pdf'));
      expect(store.fetched, ['student:f1']);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('$_className · PDFs'.toUpperCase()), findsOneWidget);
      expect(find.text('The pages of the PDF'), findsOneWidget);
      expect(find.text('Page 1 of 12'), findsOneWidget);
      await _press(t, 'Download');
      expect(store.saved, ['Chapter 1.pdf']);
      expect(find.text('Saved to Downloads'), findsOneWidget);
      await _press(t, 'Back');
      expect(find.text('Chapter 1.pdf'), findsOneWidget, reason: 'back on the class page');
      await _end(t);
    });

    testWidgets('opening a photo shows it to zoom into, with no page count', (t) async {
      await _classPage(t);
      await _tap(t, find.text('Paper 1.png'));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.textContaining('Page '), findsNothing);
      expect(find.text('Paper 1'), findsOneWidget);
      await _press(t, 'Download');
      expect(store.saved, ['Paper 1.png']);
      await _end(t);
    });

    testWidgets('a file that cannot be opened says so, cannot be downloaded, and can be tried again', (t) async {
      await _classPage(t);
      store.failWith = 'The file could not be opened. Try again.';
      await _tap(t, find.text('Chapter 1.pdf'));
      expect(find.text('Could not load this'), findsOneWidget);
      expect(find.text('The file could not be opened. Try again.'), findsOneWidget);
      final download = find.byWidgetPredicate((w) => w is PrimaryButton && w.label == 'Download');
      expect(t.widget<PrimaryButton>(download).onTap, isNull);
      store.failWith = null;
      await _press(t, 'Try again');
      expect(find.text('Page 1 of 12'), findsOneWidget);
      expect(t.widget<PrimaryButton>(download).onTap, isNotNull);
      await _end(t);
    });

    testWidgets('a class whose files are gone says so, and a shelf that cannot load can be tried again', (t) async {
      _studentSession();
      _screen(t);
      Widget page() => MaterialApp(theme: buildTheme(Brightness.light), home: LibraryClassScreen(shelfKey: _shelfKey, name: _className));
      await t.pumpWidget(page());
      await _settle(t);
      expect(find.text('No files here yet'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      server.studentDown = true;
      await t.pumpWidget(page());
      await _settle(t);
      expect(find.text('Could not load this'), findsOneWidget);
      server.studentDown = false;
      server.student = _theirShelves();
      await _press(t, 'Try again');
      expect(find.text('PDFs'), findsOneWidget);
      await _end(t);
    });
  });

  // ================================================================ a row of a file that is being added

  group('a file that is being added', () {
    UploadJob job(String name, int size, UploadState state, {int sent = 0, String? problem, bool offline = false, bool retryable = true}) =>
        UploadJob(_shelfKey, 's1', LibraryEnv.fake(name, size))
          ..state = state
          ..sent = sent
          ..problem = problem
          ..offline = offline
          ..retryable = retryable;

    Future<void> show(WidgetTester t, UploadJob j) async {
      _screen(t, h: 600);
      await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: UploadRowView(job: j, onCancel: () {}, onRetry: () {}))));
    }

    testWidgets('waiting says so and can be stopped', (t) async {
      await show(t, job('Notes.pdf', 2 * mb, UploadState.waiting));
      expect(find.text('Notes.pdf'), findsOneWidget);
      expect(find.text('Waiting · 2.0 MB'), findsOneWidget);
      expect(_button('Stop adding Notes.pdf'), findsOneWidget);
      expect(find.byType(Track), findsNothing);
    });

    testWidgets('sending shows the percent and a bar', (t) async {
      await show(t, job('Notes.pdf', 2 * mb, UploadState.sending, sent: mb));
      expect(find.text('2.0 MB · 50%'), findsOneWidget);
      expect(find.byType(Track), findsOneWidget);
      expect(_button('Stop adding Notes.pdf'), findsOneWidget);
    });

    testWidgets('finishing says almost done, with the bar full', (t) async {
      await show(t, job('Notes.pdf', 2 * mb, UploadState.finishing, sent: 2 * mb));
      expect(find.text('Almost done'), findsOneWidget);
      expect(t.widget<Track>(find.byType(Track)).fraction, 1);
    });

    testWidgets('stopped for no signal says how far it got and offers Try again, not Stop', (t) async {
      await show(t, job('Notes.pdf', 2 * mb, UploadState.stopped, sent: mb, problem: 'no signal', offline: true));
      expect(find.text('Stopped at 50%, no signal'), findsOneWidget);
      expect(_button('Try again'), findsOneWidget);
      expect(_button('Stop adding Notes.pdf'), findsNothing);
    });

    testWidgets('stopped for good gives the reason and only a way to remove it', (t) async {
      await show(t, job('Notes.pdf', 2 * mb, UploadState.stopped, problem: 'The Library is full.', retryable: false));
      expect(find.text('The Library is full.'), findsOneWidget);
      expect(_button('Remove Notes.pdf'), findsOneWidget);
      expect(_button('Try again'), findsNothing);
    });

    testWidgets('a photo has a photo\'s picture and a PDF a page\'s', (t) async {
      await show(t, job('IMG_1.jpg', mb, UploadState.waiting));
      expect(t.widget<FileTile>(find.byType(FileTile)).photo, isTrue);
      await show(t, job('Notes.pdf', mb, UploadState.waiting));
      expect(t.widget<FileTile>(find.byType(FileTile)).photo, isFalse);
    });
  });

  // ================================================================ searching

  group('searching the Library', () {
    testWidgets('there is a search box once a file is on the shelf, and not before', (t) async {
      server.seed('PDFs');
      await _group(t);
      expect(find.byType(TextField), findsNothing, reason: 'nothing to search yet');
      await _end(t);
    });

    testWidgets('typing finds files in every section, says where each is, and clearing brings the sections back', (t) async {
      server.seed('PDFs', [('Mid-term answers.pdf', mb), ('Chapter 4 notes.pdf', _pdfSize)]);
      server.seed('Test papers', [('Mid-term 2025.pdf', 2 * mb), ('Blueprint.jpg', 300 * 1024)]);
      await _group(t);
      expect(find.text('Search files'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'MID');
      await t.pump();
      expect(find.text('Found'), findsOneWidget);
      expect(_counts(t), [2]);
      expect(find.text('Mid-term answers.pdf'), findsOneWidget);
      expect(find.text('Mid-term 2025.pdf'), findsOneWidget);
      expect(find.text('Chapter 4 notes.pdf'), findsNothing);
      expect(find.textContaining('in PDFs · PDF · 1.0 MB'), findsOneWidget);
      expect(find.textContaining('in Test papers · PDF · 2.0 MB'), findsOneWidget);
      expect(_button('Add a section'), findsNothing, reason: 'the sections are out of the way while searching');
      await _press(t, 'Clear the search');
      expect(find.text('Found'), findsNothing);
      expect(_counts(t), [2, 2]);
      expect(find.text('Chapter 4 notes.pdf'), findsOneWidget);
      expect(find.text('Search files'), findsOneWidget);
      await _end(t);
    });

    testWidgets('a word that no file has says so, and the extension is not searched', (t) async {
      server.seed('PDFs', [('Chapter 4 notes.pdf', _pdfSize)]);
      await _group(t);
      await t.enterText(find.byType(TextField), 'zebra');
      await t.pump();
      expect(find.text('No file has "zebra" in its name.'), findsOneWidget);
      expect(find.text('Chapter 4 notes.pdf'), findsNothing);
      await t.enterText(find.byType(TextField), 'pdf');
      await t.pump();
      expect(find.text('No file has "pdf" in its name.'), findsOneWidget, reason: 'every file ends in .pdf, so that would find them all for nothing');
      await _end(t);
    });

    testWidgets('a file that was found still has its options, so it can be renamed from there', (t) async {
      server.seed('PDFs', [('Mid-term answers.pdf', mb)]);
      await _group(t);
      await t.enterText(find.byType(TextField), 'mid');
      await t.pump();
      await _press(t, 'Options for Mid-term answers.pdf');
      for (final item in ['Rename', 'Move to another section', 'Delete this file']) {
        expect(_button(item), findsWidgets, reason: item);
      }
      await _press(t, 'Close');
      await _end(t);
    });

    testWidgets('a student searches a class the same way, and can download from what was found', (t) async {
      await _classPage(t);
      expect(find.text('Search files'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'chapter');
      await t.pump();
      expect(find.text('Found'), findsOneWidget);
      expect(_counts(t), [2]);
      expect(find.textContaining('in PDFs · PDF'), findsNWidgets(2));
      expect(find.text('Algebra book.pdf'), findsNothing);
      await _press(t, 'Download Chapter 2.pdf');
      expect(store.saved, ['Chapter 2.pdf']);
      await t.enterText(find.byType(TextField), 'nothing like this');
      await t.pump();
      expect(find.text('No file has "nothing like this" in its name.'), findsOneWidget);
      await _press(t, 'Clear the search');
      expect(_counts(t), [2, 1, 1]);
      await _end(t);
    });

    test('findFiles looks in every section, in shelf order, ignoring capitals and the extension', () {
      final sections = [
        LibSection('s1', 'PDFs', [LibFile.fromJson(LibraryServer.fileJson('f1', 's1', 'Mid-term answers.pdf', mb)), LibFile.fromJson(LibraryServer.fileJson('f2', 's1', 'Notes.pdf', mb))]),
        LibSection('s2', 'Papers', [LibFile.fromJson(LibraryServer.fileJson('f3', 's2', 'MID-TERM 2025.pdf', mb))]),
      ];
      expect([for (final x in findFiles(sections, 'mid')) x.file.id], ['f1', 'f3']);
      expect([for (final x in findFiles(sections, ' Mid-Term ')) x.section.name], ['PDFs', 'Papers']);
      expect(findFiles(sections, 'pdf'), isEmpty);
      expect(findFiles(sections, ''), isEmpty);
      expect(findFiles(sections, '   '), isEmpty);
    });

    test('highlighted marks the first stretch that matches, in any case, and nothing when none does', () {
      final style = const TextStyle(fontWeight: FontWeight.w500);
      final span = highlighted('Mid-term answers.pdf', 'MID', style);
      final parts = span.children!.cast<TextSpan>();
      expect([for (final p in parts) p.toPlainText()], ['', 'Mid', '-term answers.pdf']);
      expect(parts[1].style!.fontWeight, FontWeight.w800);
      expect(parts[0].style!.fontWeight, FontWeight.w500);
      expect(highlighted('Notes.pdf', 'zebra', style).toPlainText(), 'Notes.pdf');
      expect(highlighted('Notes.pdf', '', style).toPlainText(), 'Notes.pdf');
    });
  });

  // ================================================================ order

  group('putting sections and files in order', () {
    Future<List<bool>> offers(WidgetTester t, String section) async {
      await _press(t, 'Options for $section');
      final r = [_button('Move up').evaluate().isNotEmpty, _button('Move down').evaluate().isNotEmpty];
      await _press(t, 'Close');
      return r;
    }

    testWidgets('a section offers Move up and Move down only where there is somewhere to go', (t) async {
      server.seed('PDFs', [('A.pdf', mb)]);
      server.seed('Books');
      server.seed('Test papers');
      await _group(t);
      expect(await offers(t, 'PDFs'), [false, true], reason: 'first');
      expect(await offers(t, 'Books'), [true, true], reason: 'in the middle');
      expect(await offers(t, 'Test papers'), [true, false], reason: 'last');
      await _end(t);
    });

    testWidgets('a lone section has nothing to move past', (t) async {
      server.seed('PDFs', [('A.pdf', mb)]);
      await _group(t);
      expect(await offers(t, 'PDFs'), [false, false]);
      await _end(t);
    });

    testWidgets('Move down puts a section below the next one at once, and tells the server the whole new order', (t) async {
      server.seed('PDFs', [('A.pdf', mb)]);
      server.seed('Books');
      server.seed('Test papers');
      await _group(t);
      await _press(t, 'Options for PDFs');
      await _press(t, 'Move down');
      expect([for (final s in server.sections) s['name']], ['Books', 'PDFs', 'Test papers']);
      expect(server.bodies.last, {'ids': ['s2', 's1', 's3']});
      expect(server.count('PUT /teacher/groups/10/sub-maths/library/sections/order'), 1);
      expect(t.getTopLeft(find.text('Books')).dy, lessThan(t.getTopLeft(find.text('PDFs')).dy));
      await _press(t, 'Options for Test papers');
      await _press(t, 'Move up');
      expect([for (final s in server.sections) s['name']], ['Books', 'Test papers', 'PDFs']);
      expect(t.getTopLeft(find.text('Test papers')).dy, lessThan(t.getTopLeft(find.text('PDFs')).dy));
      await _end(t);
    });

    testWidgets('a course\'s shelf is put in order the same way, on its own address', (t) async {
      server.seed('Handouts', [('A.pdf', mb)]);
      server.seed('Recordings');
      await _course(t);
      await _press(t, 'Options for Handouts');
      await _press(t, 'Move down');
      expect([for (final s in server.sections) s['name']], ['Recordings', 'Handouts']);
      expect(server.count('PUT /teacher/courses/c-1/library/sections/order'), 1);
      await _end(t);
    });

    testWidgets('a file moves up and down inside its section, and the first and last cannot go further', (t) async {
      server.seed('PDFs', [('A.pdf', mb), ('B.pdf', mb), ('C.pdf', mb)]);
      await _group(t);
      await _press(t, 'Options for A.pdf');
      expect(_button('Move up'), findsNothing, reason: 'first');
      expect(_button('Move down'), findsWidgets);
      await _press(t, 'Move down');
      expect(_names(server.sections.single), ['B.pdf', 'A.pdf', 'C.pdf']);
      expect(server.bodies.last, {'ids': ['f2', 'f1', 'f3']});
      expect(server.count('PUT /teacher/library/sections/s1/files/order'), 1);
      await _press(t, 'Options for C.pdf');
      expect(_button('Move down'), findsNothing, reason: 'last');
      await _press(t, 'Move up');
      expect(_names(server.sections.single), ['B.pdf', 'C.pdf', 'A.pdf']);
      expect(t.getTopLeft(find.text('C.pdf')).dy, lessThan(t.getTopLeft(find.text('A.pdf')).dy));
      await _end(t);
    });

    testWidgets('an order the server refuses is explained, and the shelf goes back to what the server has', (t) async {
      server.seed('PDFs', [('A.pdf', mb)]);
      server.seed('Books');
      await _group(t);
      server.refuseOrder = true;
      await _press(t, 'Options for PDFs');
      await _press(t, 'Move down');
      expect(find.text('That did not work'), findsOneWidget);
      expect(find.text('This list changed since you opened it. Look at it again, then move things.'), findsOneWidget);
      await _press(t, 'OK');
      expect([for (final s in server.sections) s['name']], ['PDFs', 'Books'], reason: 'the server kept its own order');
      expect(t.getTopLeft(find.text('PDFs')).dy, lessThan(t.getTopLeft(find.text('Books')).dy), reason: 'and so does the screen');
      await _end(t);
    });
  });

  // ================================================================ telling the students

  group('telling the students about new files', () {
    testWidgets('a batch of files is one notice, sent once they have all gone up', (t) async {
      server.seed('PDFs');
      await _group(t);
      final gate = Completer<void>();
      net.hold = gate.future;
      sources.pdfs = [LibraryEnv.fake('A.pdf', mb), LibraryEnv.fake('B.pdf', mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 400);
      expect(server.count('POST /teacher/library/announce'), 0, reason: 'nothing has finished yet');
      gate.complete();
      await _settle(t, 1500);
      expect(server.count('POST /teacher/library/announce'), 1, reason: 'one notice for the whole batch');
      expect(server.announced, ['f1', 'f2']);
      expect(server.announced, [for (final x in server.sections.single['files'] as List) x['id']]);
      await _end(t);
    });

    testWidgets('with no signal the notice waits, and goes with the next batch', (t) async {
      server.seed('PDFs');
      await _group(t);
      server.announceOffline = true;
      sources.pdfs = [LibraryEnv.fake('A.pdf', mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 1500);
      expect(server.announced, isEmpty);
      expect(server.files, 1, reason: 'the file is on the shelf all the same');
      expect(find.text('That did not work'), findsNothing, reason: 'a notice that could not be sent is not an error to show');
      server.announceOffline = false;
      sources.pdfs = [LibraryEnv.fake('B.pdf', mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 1500);
      expect(server.announced, ['f1', 'f2']);
      await _end(t);
    });

    testWidgets('a file that never went up tells nobody', (t) async {
      server.seed('PDFs');
      await _group(t);
      server.refuseStart = (status: 413, code: 'library_full', message: 'The Library is full. Delete some files to make room.');
      sources.pdfs = [LibraryEnv.fake('Notes.pdf', 2 * mb)];
      await _addFileVia(t, 'A PDF from this phone', ms: 800);
      expect(server.count('POST /teacher/library/announce'), 0);
      await _press(t, 'Remove Notes.pdf', ms: 300);
      await _end(t);
    });
  });

  // ================================================================ the small pieces

  group('the small pieces', () {
    test('sizeLabel rounds a size to a figure a person can read', () {
      expect(sizeLabel(0), '1 KB');
      expect(sizeLabel(1), '1 KB');
      expect(sizeLabel(1024), '1 KB');
      expect(sizeLabel(1025), '2 KB');
      expect(sizeLabel(412 * 1024), '412 KB');
      expect(sizeLabel(mb - 1), '1023 KB');
      expect(sizeLabel(mb), '1.0 MB');
      expect(sizeLabel(_pdfSize), '3.8 MB');
      expect(sizeLabel(62 * mb), '62.0 MB');
      expect(sizeLabel(100 * mb), '100 MB');
    });

    test('contentTypeOf knows a PDF and the photos, and nothing else, by the end of the name', () {
      expect(contentTypeOf('a.pdf'), 'application/pdf');
      expect(contentTypeOf('A.PDF'), 'application/pdf');
      expect(contentTypeOf('p.jpg'), 'image/jpeg');
      expect(contentTypeOf('p.JPEG'), 'image/jpeg');
      expect(contentTypeOf('p.png'), 'image/png');
      expect(contentTypeOf('p.webp'), 'image/webp');
      expect(contentTypeOf('notes.docx'), isNull);
      expect(contentTypeOf('archive.zip'), isNull);
      expect(contentTypeOf('noextension'), isNull);
      expect(contentTypeOf('p.pdf.exe'), isNull);
    });

    test('photoName names a camera photo by when it was taken', () {
      expect(photoName(DateTime(2026, 11, 2, 17, 42)), 'Photo 2 Nov 2026 5.42 pm.jpg');
      expect(photoName(DateTime(2026, 11, 2, 9, 5)), 'Photo 2 Nov 2026 9.05 am.jpg');
      expect(photoName(DateTime(2026, 11, 2, 12, 0)), 'Photo 2 Nov 2026 12.00 pm.jpg');
      expect(photoName(DateTime(2026, 11, 2, 0, 30)), 'Photo 2 Nov 2026 12.30 am.jpg');
      expect(photoName(DateTime(2026, 11, 2, 17, 42), ext: 'png'), 'Photo 2 Nov 2026 5.42 pm.png');
    });

    test('galleryPhotoName keeps a real name, names a bare number by when it was picked, and numbers a repeat', () {
      final t = DateTime(2026, 11, 2, 23, 34);
      final used = <String, int>{};
      expect(galleryPhotoName('Whiteboard photo.png', t, used), 'Whiteboard photo.png');
      expect(galleryPhotoName('IMG_2041.jpg', t, used), 'IMG_2041.jpg');
      expect(galleryPhotoName('1000000024.png', t, used), 'Photo 2 Nov 2026 11.34 pm.png');
      expect(galleryPhotoName('1000000025.PNG', t, used), 'Photo 2 Nov 2026 11.34 pm (2).png');
      expect(galleryPhotoName('1000000026.jpeg', t, used), 'Photo 2 Nov 2026 11.34 pm.jpg');
      expect(galleryPhotoName('1000000027.png', t, used), 'Photo 2 Nov 2026 11.34 pm (3).png');
      expect(galleryPhotoName('Whiteboard photo.png', t, used), 'Whiteboard photo (2).png');
      expect(galleryPhotoName('2026.jpg', t, <String, int>{}), 'Photo 2 Nov 2026 11.34 pm.jpg', reason: 'a year is only a number too');
    });

    test('sliceOf cuts the bytes between two places out of a stream that can only be read from its start', () async {
      Stream<List<int>> chunks() => Stream.fromIterable([
            [for (var i = 0; i < 10; i++) i],
            [for (var i = 10; i < 20; i++) i],
            [for (var i = 20; i < 30; i++) i],
          ]);
      Future<List<int>> read(int start, int end) async => [for (final c in await sliceOf(chunks(), start, end).toList()) ...c];
      expect(await read(0, 30), [for (var i = 0; i < 30; i++) i]);
      expect(await read(5, 25), [for (var i = 5; i < 25; i++) i]);
      expect(await read(12, 14), [12, 13]);
      expect(await read(0, 10), [for (var i = 0; i < 10; i++) i]);
      expect(await read(29, 30), [29]);
      expect(await read(30, 40), isEmpty);
      expect(await read(10, 10), isEmpty);
    });

    test('a file knows its title, the name a saved copy gets, and how it reads in a row', () {
      LibFile file(String name, {String? type, Object? added = 'x'}) {
        final j = LibraryServer.fileJson('f1', 's1', name, _pdfSize, type: type);
        if (added != 'x') j['created_at'] = added;
        return LibFile.fromJson(j);
      }

      expect(file('Chapter 4 notes.pdf').title, 'Chapter 4 notes');
      expect(file('Chapter 4 notes.pdf').saveName, 'Chapter 4 notes.pdf');
      expect(file('Chapter 4 notes', type: 'application/pdf').saveName, 'Chapter 4 notes.pdf', reason: 'a name with no type gets the one the file needs');
      expect(file('Chapter 4 notes', type: 'image/png').saveName, 'Chapter 4 notes.png');
      expect(file('Chapter 4 notes', type: 'image/webp').saveName, 'Chapter 4 notes.webp');
      expect(file('Chapter 4 notes', type: 'image/jpeg').saveName, 'Chapter 4 notes.jpg');
      expect(file('Scan.JPG', type: 'image/jpeg').title, 'Scan');
      expect(file('Scan.JPG', type: 'image/jpeg').saveName, 'Scan.JPG');
      final pdf = file('A.pdf');
      expect(pdf.isPdf, isTrue);
      expect(pdf.meta, startsWith('PDF · 3.8 MB · '));
      expect(pdf.meta, endsWith(fmt.shortDate(pdf.added!)));
      expect(file('P.png').meta, startsWith('Photo · 3.8 MB · '));
      expect(file('A.pdf', added: null).meta, 'PDF · 3.8 MB', reason: 'no date to show');
    });

    test('a shelf knows where it is on the server and what its uploads are filed under', () {
      const group = LibShelf.group(10, 'sub-maths');
      expect(group.key, _shelfKey);
      expect(group.path, '/teacher/groups/10/sub-maths/library');
      const course = LibShelf.course('c-1');
      expect(course.key, 'course:c-1');
      expect(course.path, '/teacher/courses/c-1/library');
    });

    test('a class shelf says how many files and sections it holds, and a class page is found again by its key', () {
      final shelves = _theirShelves();
      final g = (shelves['groups'] as List).single as Map;
      final group = ClassShelf(
        key: _shelfKey,
        isCourse: false,
        title: '10th Maths',
        sections: [for (final s in g['sections'] as List) LibSection.fromJson(Map<String, dynamic>.from(s as Map))],
      );
      expect(group.files, 4);
      expect(group.meta, '4 files in 3 sections');
      final c = (shelves['courses'] as List).single as Map;
      final course = ClassShelf(key: 'course:c-1', isCourse: true, title: 'Spoken English, Batch 1', sections: [LibSection.fromJson(Map<String, dynamic>.from((c['sections'] as List).single as Map))]);
      expect(course.meta, '1 file in 1 section');
      expect(libraryClassPath(group), '/s/library/class?k=group%3A10%3Asub-maths&name=10th%20Maths');
    });

    test('a stand-in picked file hands out the bytes between two places', () async {
      final file = LibraryEnv.fake('A.pdf', 100);
      expect(file.contentType, 'application/pdf');
      expect(LibraryEnv.fake('p.png', 1).contentType, 'image/png');
      final bytes = [for (final c in await file.open(10, 30).toList()) ...c];
      expect(bytes, hasLength(20));
      expect(bytes.every((b) => b == 0), isTrue);
    });
  });
}
