import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/api.dart';
import 'core/brand.dart';
import 'core/changes.dart';
import 'core/device.dart';
import 'core/push.dart';
import 'core/screen_guard.dart';
import 'core/session.dart';
import 'core/updater.dart';
import 'router.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Push.start();
  await Device.load();
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
    updater.start();
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) updater.resumed();
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
    // Subtle motion: screens fade forward over a short slide (Android's own transition).
    final theme = buildTheme(b).copyWith(
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values) p: const FadeForwardsPageTransitionsBuilder(),
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
      // Every touch counts as the phone being in use, which keeps screens checking for news.
      child: Listener(
        onPointerDown: (_) => changes.lastTouch = DateTime.now(),
        child: MaterialApp.router(
          title: appName,
          debugShowCheckedModeBanner: false,
          theme: theme,
          routerConfig: _router,
        ),
      ),
    );
  }
}
