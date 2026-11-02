import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import 'classes_screen.dart' show addClass;
import 'common.dart';
import 'make_test.dart';
import 'papers_screens.dart' show paperGroup, paperName;
import 'tests_screens.dart' show TestRow;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

// ---------------------------------------------------------------- home

/// The tutor's home, in the order a tutor needs it: one button to make a test, what needs her, the tests students can write now,
/// the ones coming up and the ones that finished lately. The classes themselves are on the Classes tab.
class TutorHome extends StatefulWidget {
  const TutorHome({super.key});

  @override
  State<TutorHome> createState() => _TutorHomeState();
}

class _TutorHomeState extends State<TutorHome> with WidgetsBindingObserver, AutoRefresh<TutorHome> {
  Map<String, dynamic>? _d;
  String? _error;

  /// The lists the tutor has opened in full (a long one shows its first few).
  final Set<String> _all = {};

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.students, Area.papers, Area.courses};

  // Students start and hand in tests all the time: check every 30 s while this is on screen.
  @override
  Duration? get pollEvery => const Duration(seconds: 30);

  @override
  Future<void> refreshQuietly() => _load(quiet: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    markLoaded();
    try {
      final d = await api.get('/teacher/home');
      if (mounted) {
        setState(() {
          _d = Map<String, dynamic>.from(d);
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted && !quiet) setState(() => _error = e.message);
    }
  }

  List<Map<String, dynamic>> _list(Map<String, dynamic> d, String key) => ((d[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  List<TestTarget> _targets(Map<String, dynamic> d) => [
        for (final g in _list(d, 'groups')) TestTarget.fromGroup(g),
        for (final c in _list(d, 'courses')) TestTarget.fromCourse(c),
      ];

  Future<void> _make(Map<String, dynamic> d) async {
    if (await makeTest(context, _targets(d)) && mounted) _load();
  }

  Future<void> _addClass() async {
    await addClass(context);
    if (mounted) _load();
  }

  Future<void> _go(String path) async {
    await context.push(path);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Kicker('${session.tuitionName} · ${DateFormat('d MMMM').format(DateTime.now())}'),
                  const SizedBox(height: 6),
                  Text('Home', style: displayStyle),
                ]),
              ),
              Pressable(
                label: 'Settings',
                onTap: () => context.push('/t/settings'),
                child: AppAvatar(name: '${session.user?['display_name'] ?? ''}', seed: '${session.user?['id'] ?? ''}', size: 42),
              ),
            ]),
          ),
          const UpdateBanner(),
          if (d == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (d == null)
            const LoadingState(inset: true, rows: 3)
          else
            ...staggered(_body(d), scope: this, prefix: 'home', stepMs: 60),
          navClearance,
        ]),
      ),
    );
  }

  /// The name of the class a test belongs to, for the line under its title.
  String _classOf(Map<String, dynamic> t, {Map<String, dynamic>? group, Map<String, dynamic>? course}) {
    if (course != null) return '${course['name']}';
    if (group != null) return groupName(group['class_level'] as int, '${group['subject']}');
    if (t['course_id'] != null) return '${t['course']}';
    return groupName(t['class_level'] as int, '${t['subject']}');
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final groups = _list(d, 'groups');
    final courses = _list(d, 'courses');
    final finished = _list(d, 'finished');
    final papers = _list(d, 'papers');
    final pending = _n(d['pending_requests']);
    final code = '${d['tuition']?['join_code'] ?? ''}';
    final noStudents = groups.every((g) => _n(g['students']) == 0) && courses.every((c) => _n(c['people']) == 0);
    final hasClass = groups.isNotEmpty || courses.isNotEmpty;

    // Every test that is open now or coming up, with the class it is for, from the groups and from the courses.
    final open = <({Map<String, dynamic> t, String cls})>[];
    final coming = <({Map<String, dynamic> t, String cls})>[];
    for (final g in groups) {
      for (final t in (g['live'] as List).cast<Map<String, dynamic>>()) {
        open.add((t: t, cls: _classOf(t, group: g)));
      }
      for (final t in (g['posted'] as List).cast<Map<String, dynamic>>()) {
        coming.add((t: t, cls: _classOf(t, group: g)));
      }
    }
    for (final c in courses) {
      for (final t in (c['live'] as List).cast<Map<String, dynamic>>()) {
        open.add((t: t, cls: _classOf(t, course: c)));
      }
      for (final t in (c['posted'] as List).cast<Map<String, dynamic>>()) {
        coming.add((t: t, cls: _classOf(t, course: c)));
      }
    }
    // What closes first comes first; a test with no closing time goes last. What opens first comes first.
    DateTime far(DateTime? t) => t ?? DateTime(9999);
    open.sort((a, b) => far(f.parseTime(a.t['closes_at'])).compareTo(far(f.parseTime(b.t['closes_at']))));
    coming.sort((a, b) => far(f.parseTime(a.t['opens_at'])).compareTo(far(f.parseTime(b.t['opens_at']))));

    Widget pad(Widget w, {double top = 0}) => Padding(padding: EdgeInsets.fromLTRB(gutter, top, gutter, 0), child: w);
    Widget rows(List<Widget> list) => pad(Column(children: [
          for (final (i, w) in list.indexed) ...[if (i > 0) const SizedBox(height: gapRow), w],
        ]));
    // A long list shows its first few, and the rest on a tap.
    Widget capped(String key, int shown, List<Widget> list) {
      final more = list.length > shown && !_all.contains(key);
      return Column(children: [
        rows(more ? list.take(shown).toList() : list),
        if (list.length > shown)
          Center(
            child: TextAction(
              more ? 'Show all ${list.length}' : 'Show fewer',
              onTap: () => setState(() => more ? _all.add(key) : _all.remove(key)),
            ),
          ),
      ]);
    }

    final needs = <Widget>[
      if (pending > 0)
        RowTile(
          leading: _badge(Ph.userPlus),
          title: pending == 1 ? '1 student wants to join' : '$pending students want to join',
          meta: 'Choose their class and subjects',
          chevron: true,
          onTap: () => _go('/t/requests'),
        ),
      if (papers.isNotEmpty)
        RowTile(
          leading: _badge(Ph.fileText),
          title: papers.length == 1 ? '1 paper to finish' : '${papers.length} papers to finish',
          meta: papers.length == 1 ? '${paperName(papers.first)} · ${paperGroup(papers.first)}' : '${paperName(papers.first)} and ${papers.length - 1} more',
          chevron: true,
          onTap: () => _go(papers.length == 1 ? '/t/papers/${papers.first['id']}' : '/t/papers'),
        ),
      if (pending == 0 && noStudents && hasClass && code.length == 6)
        RowTile(
          leading: _badge(Ph.shareNetwork),
          title: 'Invite your students',
          meta: 'Join code ${code.substring(0, 3)}-${code.substring(3)}',
          chevron: true,
          onTap: () => _go('/t/code'),
        ),
    ];

    return [
      if (_error != null) pad(InlineNotice(_error!, icon: Ph.warning), top: 16),
      if (!hasClass)
        EmptyState(
          icon: Ph.users,
          title: 'No classes yet',
          body: 'Add a class, like 10th Maths. Then you can add your students and make your first test.',
          action: PrimaryButton('Add a class', leadingIcon: Ph.plus, onTap: _addClass),
        )
      else
        pad(PrimaryButton('Make tests', leadingIcon: Ph.plus, onTap: () => _make(d)), top: 18),
      // What needs the tutor, then every test in one list: each row says by its tag whether it is open now, coming up or finished.
      if (needs.isNotEmpty) pad(Column(children: [for (final (i, w) in needs.indexed) ...[if (i > 0) const SizedBox(height: gapRow), w]]), top: 16),
      if (hasClass && open.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
          child: Fig('No test is open right now.', style: bodyStyle.copyWith(color: muted)),
        ),
      if (open.isNotEmpty || coming.isNotEmpty || finished.isNotEmpty) ...[
        pad(const SizedBox(height: 0), top: 10),
        capped('tests', 8, [
          for (final o in open) _OpenTest(t: o.t, cls: o.cls, onTap: () => _go('/t/tests/${o.t['id']}')),
          for (final o in coming) _ComingTest(t: o.t, cls: o.cls, onTap: () => _go('/t/tests/${o.t['id']}')),
          for (final t in finished) _FinishedTest(t: t, cls: _classOf(t), onTap: () => _go('/t/tests/${t['id']}')),
        ]),
      ],
      if (finished.isNotEmpty)
        pad(
          Fig('Older tests are on each class\'s page, under Classes.', style: labelStyle),
          top: 12,
        ),
      if (hasClass && open.isEmpty && coming.isEmpty && finished.isEmpty)
        EmptyState(
          icon: Ph.exam,
          title: 'No tests yet',
          body: 'Tap Make tests. Add question papers and AI reads the questions, or describe a test and AI writes it.',
        ),
    ];
  }

  /// The soft square an item that needs the tutor starts with.
  Widget _badge(IconData icon) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: warningSoft, borderRadius: BorderRadius.circular(rSmall)),
        child: Icon(icon, size: 20, color: warning),
      );
}

// ---------------------------------------------------------------- test rows

/// A test students can write now: its name, its class and when it closes, and how many have handed it in.
class _OpenTest extends StatelessWidget {
  const _OpenTest({required this.t, required this.cls, required this.onTap});
  final Map<String, dynamic> t;
  final String cls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final closes = f.parseTime(t['closes_at']);
    return TestRow(
      t: t,
      state: 'open',
      meta: '$cls · ${closes == null ? 'open' : 'closes ${f.whenDate(closes)}'}',
      onTap: onTap,
    );
  }
}

/// A test posted for later: its name, its class, and the day, date and time it opens.
class _ComingTest extends StatelessWidget {
  const _ComingTest({required this.t, required this.cls, required this.onTap});
  final Map<String, dynamic> t;
  final String cls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final opens = f.parseTime(t['opens_at']);
    return TestRow(
      t: t,
      state: 'upcoming',
      // The day name and date are always there; "tomorrow" alone leaves her to work out which day that is.
      meta: '$cls · opens ${opens == null ? 'later' : f.whenDate(opens)}',
      onTap: onTap,
    );
  }
}

/// A test that has finished: its name, its class and when it closed, and how many handed it in.
class _FinishedTest extends StatelessWidget {
  const _FinishedTest({required this.t, required this.cls, required this.onTap});
  final Map<String, dynamic> t;
  final String cls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final closes = f.parseTime(t['closes_at']);
    // Everyone it was given to handed it in before its closing time: it finished early.
    final early = closes != null && closes.isAfter(DateTime.now());
    return TestRow(
      t: t,
      state: 'closed',
      meta: '$cls · ${closes == null || early ? 'all handed in' : 'closed ${f.dayDate(closes)}'}',
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------- papers to finish

/// Every question paper the tutor started and has not finished, so one left half way is easy to find again.
class PapersToFinishScreen extends StatefulWidget {
  const PapersToFinishScreen({super.key});

  @override
  State<PapersToFinishScreen> createState() => _PapersToFinishScreenState();
}

class _PapersToFinishScreenState extends State<PapersToFinishScreen> with WidgetsBindingObserver, AutoRefresh<PapersToFinishScreen> {
  List<Map<String, dynamic>>? _papers;
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.papers, Area.tests};

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    markLoaded();
    try {
      final d = await api.get('/teacher/home');
      if (mounted) {
        setState(() {
          _papers = ((d['papers'] as List?) ?? const []).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// What is left to do on a paper, in a few words.
  String _left(Map<String, dynamic> p) {
    final toCheck = _n(p['to_check']);
    if (toCheck > 0) return '${f.count(toCheck, 'question')} to check';
    final unread = _n(p['page_count']) - _n(p['pages_read']);
    if (unread > 0) return '${_n(p['pages_read'])} of ${f.count(_n(p['page_count']), 'page')} read';
    return 'Ready to make a test';
  }

  Future<void> _open(Map<String, dynamic> p) async {
    await context.push('/t/papers/${p['id']}');
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final papers = _papers;
    return PushedPanel(
      onRefresh: _load,
      kicker: 'Question papers',
      title: 'Papers to finish',
      children: [
        const SizedBox(height: 18),
        if (papers == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (papers == null)
          const LoadingState(rows: 3)
        else if (papers.isEmpty)
          const EmptyState(icon: Ph.fileText, title: 'Nothing is waiting', body: 'Every paper you started is finished.')
        else
          for (final (i, p) in papers.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              leading: Icon(Ph.fileText, size: 22, color: ink),
              title: paperName(p),
              meta: '${paperGroup(p)} · ${_left(p)}',
              chevron: true,
              onTap: () => _open(p),
            ),
          ],
      ],
    );
  }
}
