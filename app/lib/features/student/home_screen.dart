import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/floating_tabs.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import 'start_card.dart';
import 'test_sections.dart';

/// A course's page, with its name so the page has its title before it has loaded.
String studentCoursePath(Map<String, dynamic> c) => '/s/courses/${c['id']}?name=${Uri.encodeComponent('${c['name']}')}';

class StudentHome extends StatefulWidget {
  const StudentHome({super.key});

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> with WidgetsBindingObserver, AutoRefresh<StudentHome> {
  List<Map<String, dynamic>>? _tests;

  /// The courses the student is in. A student with none sees the class's tests and nothing else.
  List<Map<String, dynamic>> _courses = const [];

  /// Which of the two a student in a class and a course is looking at: 0 Tests, 1 Courses.
  int _tab = 0;
  String? _error;
  bool _loading = false;

  @override
  Set<Area> get refreshAreas => {Area.student};

  // A new test from the teacher shows up within a minute while this is on screen.
  @override
  Duration? get pollEvery => const Duration(seconds: 60);

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    markLoaded();
    setState(() => _loading = true);
    try {
      final r = await api.get('/student/home');
      _tests = (r['tests'] as List).cast<Map<String, dynamic>>();
      // The server says how many courses the student is in (an older server says nothing: none).
      final n = (r['courses'] as num?)?.toInt() ?? 0;
      _courses = n == 0 ? const [] : ((await api.get('/student/courses'))['courses'] as List).cast<Map<String, dynamic>>();
      _error = null;
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String path) async {
    await context.push(path);
    _load();
  }

  /// A test that has not been started asks first (what it holds, when the marks show); one under way carries on.
  Future<void> _start(Map<String, dynamic> t) async {
    if (t['state'] != 'in_progress' && !await confirmStart(context, t)) return;
    if (mounted) _open('/s/write/${t['id']}');
  }

  /// A student in several tuitions chooses which one the home shows.
  Future<void> _switchTuition() async {
    final c = await showChoices<String>(
      context,
      title: 'Tuition',
      options: [for (final t in session.activeTuitions) Choice('${t['id']}', '${t['name']}')],
      selected: session.tuitionId,
    );
    if (c?.value != null) session.switchTuition(c!.value!);
  }

  @override
  Widget build(BuildContext context) {
    final user = session.user ?? {};
    final tests = _tests;
    // A person with no class (only in courses) opens straight on their courses. A student in a class and in a
    // course has two tabs, kept apart so a course never looks like part of the class.
    final inClass = session.classLevel != null;
    final tabs = inClass && _courses.isNotEmpty;
    final coursesOnly = !inClass;
    final showCourses = coursesOnly || (tabs && _tab == 1);
    final kicker = inClass && !showCourses ? '${session.tuitionName} · ${className(session.classLevel)}' : session.tuitionName;
    final title = showCourses && !coursesOnly ? 'Courses' : session.firstName;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: SafeArea(
            child: PullToRefresh(
              onRefresh: _load,
              child: ListView(padding: EdgeInsets.only(top: 8, bottom: tabs ? 110 : 32), physics: const AlwaysScrollableScrollPhysics(), children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: gutter),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const SizedBox(height: 14),
                        session.hasChoice
                            ? Pressable(
                                label: 'Change tuition',
                                onTap: _switchTuition,
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Flexible(child: Kicker(kicker)),
                                  const SizedBox(width: 6),
                                  Icon(Ph.caretDown, size: 13, color: faint),
                                ]),
                              )
                            : Kicker(kicker),
                        const SizedBox(height: 6),
                        Text(title, style: displayStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    Pressable(
                      label: 'Profile',
                      onTap: () => context.push('/s/profile'),
                      child: AppAvatar(name: '${user['display_name'] ?? ''}', seed: '${user['id'] ?? ''}', size: 42),
                    ),
                  ]),
                ),
                const UpdateBanner(),
                if (tests == null && _error != null)
                  ErrorState(message: _error!, onRetry: _load)
                else if (tests == null)
                  const _HomeSkeleton()
                else ...[
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
                      child: InlineNotice(_error!, icon: Ph.warning),
                    ),
                  ...(showCourses ? _courseSections(withNote: tabs) : _sections(tests)),
                ],
              ]),
            ),
          ),
        ),
        if (tabs)
          FloatingTabs.positioned(
            context,
            child: FloatingTabs(
              items: const [(Ph.exam, 'Tests'), (Ph.graduationCap, 'Courses')],
              index: _tab,
              onTap: (i) => setState(() => _tab = i),
            ),
          ),
      ]),
    );
  }

  List<Widget> _sections(List<Map<String, dynamic>> tests) => staggered(
        testSections(
          context,
          tests,
          onStart: _start,
          onOpen: _open,
          onAllResults: () => context.push('/s/results'),
        ),
        scope: this,
        prefix: 'home',
        stepMs: 70,
      );

  /// The student's courses, one row each. Under a Courses tab a note says these are not the class's tests.
  List<Widget> _courseSections({required bool withNote}) {
    if (_courses.isEmpty) {
      return [
        const SizedBox(height: 40),
        const EmptyState(
          icon: Ph.graduationCap,
          title: 'Nothing here yet',
          body: 'Your tutor has not added you to a class or a course yet. When they do, it shows up here.',
        ),
      ];
    }
    return staggered(
      [
        if (withNote)
          const Padding(
            padding: EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
            child: InlineNotice('Tests here are only for your courses. Your class tests are under Tests.', tone: Tone.neutral, icon: Ph.graduationCap),
          )
        else
          SectionRule('Your courses', count: _courses.length),
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, withNote ? 16 : 0, gutter, 0),
          child: Column(children: [
            for (final (i, c) in _courses.indexed) ...[if (i > 0) const SizedBox(height: gapRow), _CourseRow(course: c, onTap: () => _open(studentCoursePath(c)))],
          ]),
        ),
      ],
      scope: this,
      prefix: 'courses',
      stepMs: 70,
    );
  }
}

/// A course the student is in: its name, whether a test is open and when it closes.
class _CourseRow extends StatelessWidget {
  const _CourseRow({required this.course, required this.onTap});
  final Map<String, dynamic> course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final open = (course['open'] as num?)?.toInt() ?? 0;
    final closes = f.parseTime(course['closes_at']);
    return RowTile(
      title: '${course['name']}',
      meta: open == 0 ? 'No test open right now' : '${f.count(open, 'test')} open${closes == null ? '' : ' · closes ${f.when(closes)}'}',
      trailing: open > 0 ? TagChip('$open open', tone: Tone.success) : null,
      chevron: true,
      onTap: onTap,
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) => const SkeletonScope(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
          child: Column(children: [
            SkeletonHero(height: 214),
            SizedBox(height: 34),
            SkeletonRows(count: 3, padding: EdgeInsets.zero),
          ]),
        ),
      );
}
