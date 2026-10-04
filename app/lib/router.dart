import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/session.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/start_screen.dart';
import 'features/student/home_screen.dart';
import 'features/student/profile_screen.dart';
import 'features/student/result_screen.dart';
import 'features/student/results_screen.dart';
import 'features/student/review_screen.dart';
import 'features/student/test_intro_screen.dart';
import 'features/student/test_screen.dart';
import 'features/teacher/teacher_routes.dart';

/// Every route swaps instantly (no-motion rule).
GoRoute page(String path, Widget Function(GoRouterState s) build) =>
    GoRoute(path: path, pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: build(s)));

GoRouter buildRouter() => GoRouter(
      initialLocation: '/start',
      refreshListenable: session,
      redirect: (context, state) {
        final loc = state.matchedLocation;
        if (!session.restored) return loc == '/start' ? null : '/start';
        if (!session.signedIn) return loc == '/login' ? null : '/login';
        final home = session.isTeacher ? '/t' : '/s';
        if (loc == '/start' || loc == '/login') return home;
        if (session.isTeacher && loc.startsWith('/s')) return home;
        if (!session.isTeacher && loc.startsWith('/t')) return home;
        return null;
      },
      routes: [
        page('/start', (_) => const StartScreen()),
        page('/login', (_) => const LoginScreen()),
        page('/s', (_) => const StudentHome()),
        page('/s/test/:id', (s) => TestIntroScreen(testId: s.pathParameters['id']!)),
        page('/s/write/:id', (s) => TestScreen(testId: s.pathParameters['id']!)),
        page('/s/result/:id', (s) => ResultScreen(attemptId: s.pathParameters['id']!, autoSubmitted: s.uri.queryParameters['auto'] == '1')),
        page('/s/review/:id', (s) => ReviewScreen(attemptId: s.pathParameters['id']!, start: int.tryParse(s.uri.queryParameters['n'] ?? '') ?? 1)),
        page('/s/results', (_) => const ResultsScreen()),
        page('/s/profile', (_) => const ProfileScreen()),
        ...teacherRoutes,
      ],
    );
