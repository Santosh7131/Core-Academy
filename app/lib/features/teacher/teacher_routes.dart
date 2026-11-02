import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../student/profile_screen.dart';
import '../student/result_screen.dart';
import '../student/review_screen.dart';
import 'classes_screen.dart';
import 'course_screens.dart';
import 'group_screens.dart';
import 'home_screen.dart';
import 'join_requests_screen.dart';
import 'make_test.dart' show MakeTests;
import 'make_tests_screen.dart';
import 'papers_screens.dart';
import 'questions_screens.dart';
import 'settings_screen.dart';
import 'share_code_screen.dart';
import 'shell.dart';
import 'students_screens.dart';
import 'tests_screens.dart';

/// A tab's own screen. Switching tabs swaps instantly, as a tab bar should.
GoRoute _tab(String path, Widget Function(GoRouterState s) build) =>
    GoRoute(path: path, pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: build(s)));

/// Forms and details fade in over the tab: the theme's fade-forwards transition.
GoRoute _page(String path, Widget Function(GoRouterState s) build) =>
    GoRoute(path: path, pageBuilder: (c, s) => MaterialPage(key: s.pageKey, child: build(s)));

int? _int(GoRouterState s, String key) => int.tryParse(s.uri.queryParameters[key] ?? '');

/// Two tabs inside the shell, Home and Groups & courses; everything else is pushed full-screen above it.
/// Students, tests, uploads and test questions all live inside a group or a course. The Groups and Courses tabs of
/// the versions before 1.8.0 are one tab now, with a switch between the two kinds (its route is still /t/classes).
final teacherRoutes = <RouteBase>[
  StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => TeacherShell(shell: shell),
    branches: [
      StatefulShellBranch(routes: [_tab('/t', (_) => const TutorHome())]),
      StatefulShellBranch(routes: [_tab('/t/classes', (_) => const ClassesScreen())]),
    ],
  ),
  GoRoute(path: '/t/groups', redirect: (_, _) => '/t/classes'),
  GoRoute(path: '/t/courses', redirect: (_, _) => '/t/classes'),
  _page('/t/papers', (_) => const PapersToFinishScreen()),
  // Making tests: several papers at once, each its own test. Opened with the class (from its page) or the classes to choose from.
  _page('/t/make', (s) {
    final m = s.extra as MakeTests?;
    return MakeTestsScreen(target: m?.target, targets: m?.targets ?? const []);
  }),
  _page('/t/courses/:id', (s) => CourseScreen(id: s.pathParameters['id']!, name: s.uri.queryParameters['name'] ?? 'Course')),
  _page(
    '/t/courses/:id/add',
    (s) => AddPeopleScreen(courseId: s.pathParameters['id']!, courseName: s.uri.queryParameters['name'] ?? 'Course'),
  ),
  _page(
    '/t/courses/:id/chat',
    (s) => ChatTestScreen(courseId: s.pathParameters['id']!, subjectName: s.uri.queryParameters['name'] ?? 'Course'),
  ),
  _page(
    '/t/groups/:cls/:subject',
    (s) => GroupScreen(
      classLevel: int.parse(s.pathParameters['cls']!),
      subjectId: s.pathParameters['subject']!,
      subjectName: s.uri.queryParameters['name'] ?? 'Group',
    ),
  ),
  _page(
    '/t/groups/:cls/:subject/chat',
    (s) => ChatTestScreen(
      classLevel: int.parse(s.pathParameters['cls']!),
      subjectId: s.pathParameters['subject']!,
      subjectName: s.uri.queryParameters['name'] ?? '',
    ),
  ),
  _page('/t/students/new', (s) => AddStudentScreen(classLevel: _int(s, 'class'), subjectId: s.uri.queryParameters['subject'])),
  // From a course's page the person is shown as that course sees them: only its tests.
  _page('/t/students/:id', (s) => StudentDetailScreen(id: s.pathParameters['id']!, courseId: s.uri.queryParameters['course'], courseName: s.uri.queryParameters['name'])),
  _page(
    '/t/papers/new',
    (s) => UploadPaperScreen(
      classLevel: _int(s, 'class'),
      subjectId: s.uri.queryParameters['subject'],
      subjectName: s.uri.queryParameters['name'],
      courseId: s.uri.queryParameters['course'],
    ),
  ),
  _page('/t/papers/:id', (s) => PaperReviewScreen(id: s.pathParameters['id']!, autoRead: s.uri.queryParameters['read'] == '1')),
  // A question opens only from a test or a paper, to fix its answer.
  _page('/t/questions/:id', (s) => QuestionEditor(id: s.pathParameters['id']!)),
  _page('/t/tests/new', (_) => const TestEditor()),
  _page('/t/tests/:id/edit', (s) => TestEditor(id: s.pathParameters['id']!)),
  _page('/t/tests/:id', (s) => TestResultsScreen(id: s.pathParameters['id']!)),
  _page('/t/attempts/:id/review', (s) => ReviewScreen(attemptId: s.pathParameters['id']!, start: int.tryParse(s.uri.queryParameters['n'] ?? '') ?? 1, teacher: true)),
  _page('/t/attempts/:id', (s) => ResultScreen(attemptId: s.pathParameters['id']!, teacher: true)),
  _page('/t/settings', (_) => const SettingsScreen()),
  _page('/t/code', (s) => ShareCodeScreen(first: s.uri.queryParameters['first'] == '1')),
  _page('/t/requests', (_) => const JoinRequestsScreen()),
  _page('/t/profile', (_) => const ProfileScreen()),
];
