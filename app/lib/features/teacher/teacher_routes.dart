import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../student/profile_screen.dart';
import '../student/result_screen.dart';
import '../student/review_screen.dart';
import 'papers_screens.dart';
import 'questions_screens.dart';
import 'settings_screen.dart';
import 'shell.dart';
import 'students_screens.dart';
import 'tests_screens.dart';
import 'today_screen.dart';

GoRoute _page(String path, Widget Function(GoRouterState s) build) =>
    GoRoute(path: path, pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: build(s)));

/// Five tabs inside the shell; every form and detail screen is pushed full-screen above it.
final teacherRoutes = <RouteBase>[
  StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => TeacherShell(shell: shell),
    branches: [
      StatefulShellBranch(routes: [_page('/t', (_) => const TodayScreen())]),
      StatefulShellBranch(routes: [_page('/t/students', (_) => const StudentsScreen())]),
      StatefulShellBranch(routes: [_page('/t/papers', (_) => const PapersScreen())]),
      StatefulShellBranch(routes: [_page('/t/questions', (_) => const QuestionsScreen())]),
      StatefulShellBranch(routes: [_page('/t/tests', (_) => const TestsScreen())]),
    ],
  ),
  _page('/t/students/new', (_) => const AddStudentScreen()),
  _page('/t/students/:id', (s) => StudentDetailScreen(id: s.pathParameters['id']!)),
  _page('/t/papers/new', (_) => const UploadPaperScreen()),
  _page('/t/papers/:id', (s) => PaperReviewScreen(id: s.pathParameters['id']!, autoRead: s.uri.queryParameters['read'] == '1')),
  _page('/t/questions/new', (_) => const QuestionEditor()),
  _page('/t/questions/:id', (s) => QuestionEditor(id: s.pathParameters['id']!)),
  _page('/t/tests/new', (_) => const TestEditor()),
  _page('/t/tests/:id/edit', (s) => TestEditor(id: s.pathParameters['id']!)),
  _page('/t/tests/:id', (s) => TestResultsScreen(id: s.pathParameters['id']!)),
  _page('/t/attempts/:id/review', (s) => ReviewScreen(attemptId: s.pathParameters['id']!, start: int.tryParse(s.uri.queryParameters['n'] ?? '') ?? 1, teacher: true)),
  _page('/t/attempts/:id', (s) => ResultScreen(attemptId: s.pathParameters['id']!, teacher: true)),
  _page('/t/settings', (_) => const SettingsScreen()),
  _page('/t/profile', (_) => const ProfileScreen()),
];
