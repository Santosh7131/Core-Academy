// Soft Structuralism token layer — copied verbatim from the design guide §6
// by tools/extract-tokens.mjs. Only the accent was renamed to its purpose.
// Do not retype values here; change the guide and re-run the script.
// ignore_for_file: unused_local_variable

import 'package:flutter/material.dart';

bool _dark = false;
bool get isDark => _dark;
void setResolvedDark(bool v) => _dark = v;   // call before the tree paints

const String fontSans = 'Geist';
const String fontMono = 'GeistMono';

// ---- surfaces
Color get bg       => _dark ? const Color(0xFF0C0C0F) : const Color(0xFFFAFAFB);
Color get card     => _dark ? const Color(0xFF16161A) : const Color(0xFFFFFFFF);
Color get cardHi   => _dark ? const Color(0xFF1E1E24) : const Color(0xFFF6F6F8);
Color get fill     => _dark ? const Color(0xFF1E1E24) : const Color(0xFFF3F3F6);
Color get hairline => _dark ? const Color(0xFF24242C) : const Color(0xFFEDEDF1);

// ---- text
Color get ink   => _dark ? const Color(0xFFF4F4F7) : const Color(0xFF0E0E11);
Color get body  => _dark ? const Color(0xFFC3C3CE) : const Color(0xFF3A3A42);
Color get muted => _dark ? const Color(0xFF90909C) : const Color(0xFF8E8E99);
Color get faint => _dark ? const Color(0xFF63636F) : const Color(0xFFB8B8C2);

// ---- primary action. NEVER use raw `ink` as a fill: it is near-white in dark.
Color get actionFill => _dark ? const Color(0xFF2E2E38) : const Color(0xFF0E0E11);
Color get actionInk  => _dark ? const Color(0xFFF4F4F7) : const Color(0xFFFAFAFB);

// ---- semantic state
Color get danger  => _dark ? const Color(0xFFFF6B5E) : const Color(0xFFE4483D);
Color get success => _dark ? const Color(0xFF3FCC8B) : const Color(0xFF1A9E62);
Color get warning => _dark ? const Color(0xFFE5A44E) : const Color(0xFFC77B1E);
Color get dangerSoft  => _dark ? const Color(0xFF3A1A18) : const Color(0xFFFEF0EE);
Color get successSoft => _dark ? const Color(0xFF12301F) : const Color(0xFFEBF8F1);
Color get warningSoft => _dark ? const Color(0xFF33240E) : const Color(0xFFFDF4E7);

// ---- the ONE accent. Single purpose: the AI paper reader (Papers tab,
// "Read with AI", the AI mark on drafted questions). Nowhere else.
const aiAccent = Color(0xFF5B3DF5);
Color get aiAccentSoft => _dark ? const Color(0xFF1E1940) : const Color(0xFFF0EDFF);

// ---- scale
const double rCard = 20, rSmall = 14, rHero = 26, rPill = 999;
const double gutter = 20, gapRow = 10, gapSec = 26;

List<BoxShadow> get e1 => _dark ? const [] : const [
  BoxShadow(color: Color(0x050E0E11), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x0F0E0E11), blurRadius: 10, offset: Offset(0, 4), spreadRadius: -6),
];
List<BoxShadow> get e2 => _dark ? const [] : const [
  BoxShadow(color: Color(0x060E0E11), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x170E0E11), blurRadius: 20, offset: Offset(0, 8), spreadRadius: -12),
];
List<BoxShadow> get e3 => _dark ? const [] : const [
  BoxShadow(color: Color(0x060E0E11), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x170E0E11), blurRadius: 26, offset: Offset(0, 12), spreadRadius: -12),
  BoxShadow(color: Color(0x1F0E0E11), blurRadius: 70, offset: Offset(0, 40), spreadRadius: -30),
];
List<BoxShadow> get e4 => _dark ? const [] : const [
  BoxShadow(color: Color(0x0A0E0E11), blurRadius: 4, offset: Offset(0, 2)),
  BoxShadow(color: Color(0x290E0E11), blurRadius: 40, offset: Offset(0, 18), spreadRadius: -14),
];

/// Borderless in light by design; dark needs a hairline because shadow cannot
/// separate planes on a near-black ground.
BoxDecoration surface({double radius = rCard, Color? color, List<BoxShadow>? shadow}) =>
    BoxDecoration(
      color: color ?? card,
      borderRadius: BorderRadius.circular(radius),
      border: _dark ? Border.all(color: hairline, width: 1) : null,
      boxShadow: shadow ?? e2,
    );

BoxDecoration sunken({double radius = rPill, Color? color}) =>
    BoxDecoration(color: color ?? fill, borderRadius: BorderRadius.circular(radius));

// ---- type scale
TextStyle get displayStyle => TextStyle(fontFamily: fontSans, fontSize: 38,
    height: 1.04, fontWeight: FontWeight.w800, letterSpacing: -1.95, color: ink);
TextStyle get titleStyle => TextStyle(fontFamily: fontSans, fontSize: 27,
    height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -1.15, color: ink);
TextStyle get sectionStyle => TextStyle(fontFamily: fontSans, fontSize: 17,
    height: 1.25, fontWeight: FontWeight.w700, letterSpacing: -0.6, color: ink);
TextStyle get rowTitleStyle => TextStyle(fontFamily: fontSans, fontSize: 14.5,
    height: 1.33, fontWeight: FontWeight.w600, letterSpacing: -0.38, color: ink);
TextStyle get bodyStyle => TextStyle(fontFamily: fontSans, fontSize: 13.8,
    height: 1.54, fontWeight: FontWeight.w500, letterSpacing: -0.22, color: body);
TextStyle get labelStyle => TextStyle(fontFamily: fontSans, fontSize: 11.5,
    height: 1.3, fontWeight: FontWeight.w600, letterSpacing: -0.1, color: muted);
TextStyle get kickerStyle => TextStyle(fontFamily: fontSans, fontSize: 11,
    height: 1.3, fontWeight: FontWeight.w600, letterSpacing: 1.0, color: faint);

/// Figures only. Never prose.
TextStyle numStyle({double size = 14, FontWeight weight = FontWeight.w700, Color? color}) =>
    TextStyle(fontFamily: fontMono, fontSize: size, height: 1.0, fontWeight: weight,
        letterSpacing: -size * 0.04, color: color ?? ink,
        fontFeatures: const [FontFeature.tabularFigures()]);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final sbg    = dark ? const Color(0xFF0C0C0F) : const Color(0xFFFAFAFB);
  final scard  = dark ? const Color(0xFF16161A) : const Color(0xFFFFFFFF);
  final sink   = dark ? const Color(0xFFF4F4F7) : const Color(0xFF0E0E11);
  final sbody  = dark ? const Color(0xFFC3C3CE) : const Color(0xFF3A3A42);
  final smuted = dark ? const Color(0xFF90909C) : const Color(0xFF8E8E99);
  final sline  = dark ? const Color(0xFF24242C) : const Color(0xFFEDEDF1);
  final sfill  = dark ? const Color(0xFF1E1E24) : const Color(0xFFF3F3F6);

  // Built EXPLICITLY. ColorScheme.fromSeed with a near-neutral seed generates a
  // BLUE-tinted tonal palette, which leaks into the date picker, text selection
  // and progress indicators. See Traps.
  final scheme = ColorScheme(
    brightness: b,
    primary: sink,            onPrimary: sbg,
    primaryContainer: sfill,  onPrimaryContainer: sink,
    secondary: smuted,        onSecondary: sbg,
    secondaryContainer: sfill, onSecondaryContainer: sink,
    tertiary: smuted,         onTertiary: sbg,
    error: dark ? const Color(0xFFFF6B5E) : const Color(0xFFE4483D),
    onError: Colors.white,
    surface: scard,           onSurface: sink,
    onSurfaceVariant: smuted, surfaceTint: Colors.transparent,
    outline: sline,           outlineVariant: sline,
    inverseSurface: sink,     onInverseSurface: sbg,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: fontSans,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: sbg,
    canvasColor: sbg,
    // Material's splash fights a borderless floating language; use a scale press.
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: sbg, surfaceTintColor: Colors.transparent,
      foregroundColor: sink, elevation: 0, scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: fontSans, fontSize: 19,
          fontWeight: FontWeight.w800, color: sink, letterSpacing: -0.7),
    ),
    dividerTheme: DividerThemeData(color: sline, thickness: 1, space: 1),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: scard, surfaceTintColor: Colors.transparent,
      headerBackgroundColor: scard, headerForegroundColor: sink,
      todayForegroundColor: WidgetStatePropertyAll(sink),
      todayBorder: BorderSide(color: sline),
      dayForegroundColor: WidgetStatePropertyAll(sink),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rHero)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: sink, selectionColor: sink.withValues(alpha: 0.18),
      selectionHandleColor: sink),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: sink, linearTrackColor: sfill),
    dialogTheme: DialogThemeData(backgroundColor: scard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rHero))),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: sink, behavior: SnackBarBehavior.floating,
      contentTextStyle: TextStyle(fontFamily: fontSans, fontSize: 13.5,
          fontWeight: FontWeight.w600, letterSpacing: -0.25, color: sbg),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSmall)),
    ),
  );
}
