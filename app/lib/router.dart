import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/session.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/signup_screen.dart';
import 'features/auth/start_screen.dart';
import 'features/student/home_screen.dart';
import 'features/student/join_screen.dart';
import 'features/student/profile_screen.dart';
import 'features/student/result_screen.dart';
import 'features/student/results_screen.dart';
import 'features/student/review_screen.dart';
import 'features/student/test_intro_screen.dart';
import 'features/student/test_screen.dart';
import 'features/teacher/setup_screen.dart';
import 'features/teacher/teacher_routes.dart';

/// Each screen fades in over the one before it: the theme's fade-forwards transition.
GoRoute page(String path, Widget Function(GoRouterState s) build) =>
    GoRoute(path: path, pageBuilder: (c, s) => MaterialPage(key: s.pageKey, child: build(s)));

GoRouter buildRouter() => GoRouter(
      initialLocation: '/start',
      refreshListenable: session,
      redirect: (context, state) {
        final loc = state.matchedLocation;
        if (!session.restored) return loc == '/start' ? null : '/start';
        if (!session.signedIn) return loc == '/login' || loc == '/signup' ? null : '/login';
        final teacher = session.isTeacher;
        final home = teacher ? '/t' : '/s';
        // A tutor with no tuition creates one first; a student with no place yet can only ask to join.
        if (session.needsTuition) {
          if (teacher) return loc == '/setup' ? null : '/setup';
          return loc == '/s/join' || loc == '/s/profile' ? null : '/s/join';
        }
        if (loc == '/start' || loc == '/login' || loc == '/signup' || loc == '/setup') return home;
        if (teacher && loc.startsWith('/s')) return home;
        if (!teacher && loc.startsWith('/t')) return home;
        return null;
      },
      routes: [
        page('/start', (_) => const StartScreen()),
        page('/login', (_) => const LoginScreen()),
        page('/signup', (_) => const TutorSignUpScreen()),
        page('/setup', (_) => const SetupScreen()),
        page('/s', (_) => const StudentHome()),
        page('/s/test/:id', (s) => TestIntroScreen(testId: s.pathParameters['id']!)),
        page('/s/write/:id', (s) => TestScreen(testId: s.pathParameters['id']!)),
        page('/s/result/:id', (s) => ResultScreen(attemptId: s.pathParameters['id']!, autoSubmitted: s.uri.queryParameters['auto'] == '1')),
        page('/s/review/:id', (s) => ReviewScreen(attemptId: s.pathParameters['id']!, start: int.tryParse(s.uri.queryParameters['n'] ?? '') ?? 1)),
        page('/s/results', (_) => const ResultsScreen()),
        page('/s/profile', (_) => const ProfileScreen()),
        page('/s/join', (_) => const JoinScreen()),
        ...teacherRoutes,
      ],
    );
