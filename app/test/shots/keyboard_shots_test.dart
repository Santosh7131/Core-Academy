// Draws the New course card with the keyboard up, as the app laid it out before the fix and as it lays it out now, on two
// phone sizes (no phone, no emulator). The card is the real one; the keyboard is a stand-in the test draws over the bottom
// of the screen, as tall as the one in the report (318 dp on a 360 x 800 phone).
//   SHOTS=1 flutter test test/shots/keyboard_shots_test.dart
// Pictures go to ../tools/out/shots (git-ignored); handover/scratch-tools/comps/make_keyboard_sheet.py puts them side by side.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/session.dart';
import 'package:core_academy/features/teacher/classes_screen.dart';
import 'package:core_academy/features/teacher/course_screens.dart';
import 'package:core_academy/theme.dart';
import 'package:core_academy/ui/kit.dart';
import 'package:core_academy/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _shots = Platform.environment['SHOTS'] == '1';
final _boundary = GlobalKey();
const _ratio = 2.5;

String _iso(Duration from) => DateTime.now().add(from).toUtc().toIso8601String();

Future<http.Response> _answer(http.Request r) async {
  if (r.url.path == '/teacher/courses' || r.url.path == '/teacher/home') {
    final body = {
      'groups': <Object?>[],
      'tuition': {'id': 't-1', 'name': 'Core Academy', 'join_code': 'KR74MQ'},
      'pending_requests': 0,
      'courses': [
        {
          'id': 'c-1', 'name': 'Maths Mock Test Series', 'created_at': _iso(const Duration(days: -9)), 'people': 3,
          'live': [
            {'id': 'y1', 'title': 'Area Related to Circles, Mock Test', 'closes_at': _iso(const Duration(hours: 3)), 'opens_at': null, 'submitted': 0, 'assigned': 3, 'writing': 1},
            {'id': 'y2', 'title': 'Surface Area and Volume, Set 1', 'closes_at': _iso(const Duration(days: 7)), 'opens_at': null, 'submitted': 0, 'assigned': 3, 'writing': 0},
          ],
          'posted': <Object?>[],
        },
        {'id': 'c-2', 'name': 'Science Mock Test Series', 'created_at': _iso(const Duration(days: -9)), 'people': 3, 'live': <Object?>[], 'posted': <Object?>[]},
      ],
    };
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});
  }
  return http.Response(jsonEncode({'error': {'code': 'not_found', 'message': 'No stub for ${r.url.path}'}}), 404);
}

/// A phone: its size in dp, and how tall its keyboard is.
typedef Phone = ({String name, double w, double h, double keyboard});

const _hisPhone = (name: 'phone-360x800', w: 360.0, h: 800.0, keyboard: 318.0);
const _smallPhone = (name: 'phone-360x640', w: 360.0, h: 640.0, keyboard: 270.0);

/// The keyboard, drawn as keys on a panel. It stands in for the phone's own, so only its height matters.
class _KeyboardStandIn extends StatelessWidget {
  const _KeyboardStandIn({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final panel = dark ? const Color(0xFF1C1D21) : const Color(0xFFD3D6DC);
    final key = dark ? const Color(0xFF3A3C42) : const Color(0xFFFFFFFF);
    final label = dark ? const Color(0xFFB4B6BE) : const Color(0xFF50525A);
    Widget row(int n, {double inset = 0}) => Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Row(children: [
              for (var i = 0; i < n; i++)
                Expanded(child: Container(margin: const EdgeInsets.all(3), decoration: BoxDecoration(color: key, borderRadius: BorderRadius.circular(8)))),
            ]),
          ),
        );
    return Container(
      color: panel,
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 18),
      child: Column(children: [
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('keyboard (drawn by the test)', style: TextStyle(fontFamily: 'Geist', fontSize: 11, color: label, decoration: TextDecoration.none))),
        row(10),
        row(10),
        row(9, inset: 16),
        row(9),
        row(5),
      ]),
    );
  }
}

/// The card as the app laid it out before the fix: centred in the whole screen and as tall as 72% of it, whatever the
/// keyboard does. Its content is the New course card's.
Future<void> _cardAsItWas(BuildContext context) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: scrim,
      transitionDuration: const Duration(milliseconds: 170),
      pageBuilder: (ctx, _, _) {
        final size = MediaQuery.sizeOf(ctx);
        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: math.min(size.width - 36, 480), maxHeight: size.height * 0.72),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  decoration: surface(radius: rHero, shadow: e4),
                  padding: const EdgeInsets.fromLTRB(22, 18, 16, 22),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text('New course', style: cardTitleStyle)),
                      CircleBtn(icon: Ph.x, label: 'Close', ground: fill, onTap: () => Navigator.of(ctx).pop()),
                    ]),
                    Fig('Name it so your people know it', style: labelStyle),
                    const SizedBox(height: 14),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 6),
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text('Course name', style: labelStyle),
                          const SizedBox(height: 8),
                          GroupedInputs(children: [
                            BareField(controller: TextEditingController(), placeholder: 'e.g. Spoken English, Batch 1', autofocus: true, capitalization: TextCapitalization.words),
                          ]),
                          const SizedBox(height: 16),
                          PrimaryButton('Create course', onTap: null),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 34; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  if (!_shots) return;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
    final image = await boundary.toImage(pixelRatio: _ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('../tools/out/shots/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await session.loadPrefs();
    for (final (family, asset) in [('Geist', 'assets/fonts/Geist.ttf'), ('GeistMono', 'assets/fonts/GeistMono.ttf'), ('PhosphorLight', 'assets/fonts/PhosphorLight.ttf')]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
    http.runWithClient(() => api.token = 'test', () => MockClient(_answer));
  });

  Future<void> scene(WidgetTester t, Phone p, {required bool dark, required bool fixed}) async {
    api.token = 'test';
    session.user = {'id': 'u-1', 'role': 'teacher', 'username': 'karthiga', 'display_name': 'Karthiga', 'class_level': null};
    session.tuitions = [
      {'id': 't-1', 'name': 'Core Academy', 'role': 'owner', 'status': 'active'},
    ];
    session.tuitionId = 't-1';
    setResolvedDark(dark);
    t.view.devicePixelRatio = _ratio;
    t.view.physicalSize = Size(p.w * _ratio, p.h * _ratio);
    t.view.viewPadding = const FakeViewPadding(top: 24 * _ratio, bottom: 16 * _ratio);
    t.view.padding = const FakeViewPadding(top: 24 * _ratio, bottom: 16 * _ratio);
    t.view.viewInsets = FakeViewPadding.zero;
    addTearDown(t.view.reset);
    final keyboard = ValueNotifier(false);
    await t.pumpWidget(RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(dark ? Brightness.dark : Brightness.light),
        builder: (context, child) => ValueListenableBuilder<bool>(
          valueListenable: keyboard,
          builder: (context, up, _) => Stack(children: [
            child!,
            if (up) Positioned(left: 0, right: 0, bottom: 0, height: p.keyboard, child: _KeyboardStandIn(dark: dark)),
          ]),
        ),
        home: const Scaffold(body: ClassesScreen()),
      ),
    ));
    await _settle(t);
    final page = t.element(find.byType(ClassesScreen));
    if (fixed) {
      unawaited(newCourse(page));
    } else {
      unawaited(_cardAsItWas(page));
    }
    await _settle(t);
    // The card's field has the focus, so the keyboard comes up: the window gets its insets and the stand-in is drawn.
    t.view.padding = const FakeViewPadding(top: 24 * _ratio);
    t.view.viewInsets = FakeViewPadding(bottom: p.keyboard * _ratio);
    keyboard.value = true;
    await _settle(t);
    await _shot(t, 'keyboard-card-${fixed ? 'after' : 'before'}-${p.name}-${dark ? 'dark' : 'light'}');
    await t.pumpWidget(const SizedBox.shrink());
  }

  for (final fixed in [false, true]) {
    testWidgets('the New course card with the keyboard up, ${fixed ? 'now' : 'as it was'}', (t) async {
      debugDisableShadows = false;
      try {
        await scene(t, _hisPhone, dark: true, fixed: fixed);
        await scene(t, _hisPhone, dark: false, fixed: fixed);
        await scene(t, _smallPhone, dark: true, fixed: fixed);
      } finally {
        debugDisableShadows = true;
      }
    });
  }
}
