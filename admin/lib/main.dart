import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/device.dart';
import 'core/session.dart';
import 'core/updater.dart';
import 'screens/login.dart';
import 'screens/shell.dart';
import 'screens/start.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Device.load();
  await session.loadPrefs();
  _resolveDark();
  runApp(const AdminApp());
  session.restore();
  updater.start();
}

/// Applies the theme choice to the token getters, as the main app does. Returns true when it changed.
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

class AdminApp extends StatefulWidget {
  const AdminApp({super.key});

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_onSession);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (_resolveDark()) _rebuildEverything();
  }

  @override
  void didChangePlatformBrightness() {
    if (_resolveDark()) _rebuildEverything();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) updater.resumed();
  }

  /// Colours are theme-resolving getters read during build, so a theme change marks every element dirty.
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
      child: MaterialApp(
        title: 'Core Academy Admin',
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            if (!session.restored) return const StartScreen();
            return session.signedIn ? const Shell() : const LoginScreen();
          },
        ),
      ),
    );
  }
}
