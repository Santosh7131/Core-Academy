import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/api.dart';
import 'core/push.dart';
import 'core/screen_guard.dart';
import 'core/session.dart';
import 'router.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Push.start();
  await session.loadPrefs();
  _resolveDark();
  runApp(const CoreAcademyApp());
}

/// Applies the theme choice to the token getters. Returns true when it changed.
bool _resolveDark() {
  final platformDark = PlatformDispatcher.instance.platformBrightness == Brightness.dark;
  final dark = switch (session.theme) {
    ThemeChoice.system => platformDark,
    ThemeChoice.light => false,
    ThemeChoice.dark => true,
  };
  final changed = dark != isDark;
  setResolvedDark(dark);
  return changed;
}

/// No route animation (Santosh's no-motion rule): screens swap instantly.
class _NoMotionTransitions extends PageTransitionsBuilder {
  const _NoMotionTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> a, Animation<double> b, Widget child) =>
      child;
}

/// No stretch or glow when a list hits its end.
class _NoMotionScroll extends MaterialScrollBehavior {
  const _NoMotionScroll();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const ClampingScrollPhysics();
}

class CoreAcademyApp extends StatefulWidget {
  const CoreAcademyApp({super.key});

  @override
  State<CoreAcademyApp> createState() => _CoreAcademyAppState();
}

class _CoreAcademyAppState extends State<CoreAcademyApp> with WidgetsBindingObserver {
  late final _router = buildRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_onSession);
    session.restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    ScreenGuard.forRole(session.user?['role'] as String?);
    Push.forSession(session.signedIn ? api.token : null);
    if (_resolveDark()) _rebuildEverything();
  }

  @override
  void didChangePlatformBrightness() {
    if (_resolveDark()) _rebuildEverything();
  }

  /// Colours are theme-resolving getters read during build, so a theme change
  /// marks every element dirty. State (an open test, a half-typed form) is kept.
  void _rebuildEverything() {
    setState(() {});
    void walk(Element e) {
      e.markNeedsBuild();
      e.visitChildren(walk);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(walk);
  }

  @override
  Widget build(BuildContext context) {
    final b = isDark ? Brightness.dark : Brightness.light;
    final theme = buildTheme(b).copyWith(
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values) p: const _NoMotionTransitions(),
      }),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: b,
        systemNavigationBarColor: bg,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
      child: MaterialApp.router(
        title: 'Core Academy',
        debugShowCheckedModeBanner: false,
        theme: theme,
        scrollBehavior: const _NoMotionScroll(),
        routerConfig: _router,
      ),
    );
  }
}
